# frozen_string_literal: true

module Chat
  class CreateMessage
    include Service::Base

    policy :no_silenced_user
    contract
    model :channel
    policy :allowed_to_join_channel
    policy :allowed_to_create_message_in_channel, class_name: Chat::Channel::MessageCreationPolicy
    model :channel_membership
    model :reply, optional: true
    policy :ensure_reply_consistency
    model :original_message, optional: true
    model :thread, optional: true
    policy :ensure_valid_thread_for_channel
    policy :ensure_thread_matches_parent
    model :uploads, optional: true
    model :message, :instantiate_message
    step :save_message
    step :create_webhook_event
    step :create_thread
    step :delete_drafts
    step :post_process_thread
    step :update_channel_last_message
    step :publish_new_message
    step :update_membership_last_read
    step :process_direct_message_channel
    step :publish_user_tracking_state

    class Contract
      attribute :chat_channel_id, :string
      attribute :in_reply_to_id, :string
      attribute :message, :string
      attribute :staged_id, :string
      attribute :upload_ids, :array
      attribute :thread_id, :string
      attribute :staged_thread_id, :string
      attribute :incoming_chat_webhook

      validates :chat_channel_id, presence: true
      validates :message, presence: true, if: -> { upload_ids.blank? }
    end

    private

    def no_silenced_user(guardian:, **)
      !guardian.is_silenced?
    end

    def fetch_channel(contract:, **)
      Chat::Channel.find_by_id_or_slug(contract.chat_channel_id)
    end

    def allowed_to_join_channel(guardian:, channel:, **)
      guardian.can_join_chat_channel?(channel)
    end

    def fetch_channel_membership(guardian:, channel:, **)
      Chat::ChannelMembershipManager.new(channel).find_for_user(guardian.user)
    end

    def fetch_reply(contract:, **)
      Chat::Message.find_by(id: contract.in_reply_to_id)
    end

    def ensure_reply_consistency(channel:, contract:, reply:, **)
      return true if contract.in_reply_to_id.blank?
      reply.chat_channel == channel
    end

    def fetch_original_message(reply:, **)
      return if reply.blank?
      reply.thread&.original_message || reply
    end

    def fetch_thread(contract:, **)
      Chat::Thread.find_by(id: contract.thread_id)
    end

    def ensure_valid_thread_for_channel(thread:, contract:, channel:, **)
      return true if thread.blank?
      thread.channel == channel
    end

    def ensure_thread_matches_parent(thread:, contract:, original_message:, reply:, **)
      return true if thread.blank?
      return true if !reply.try(:thread) && !original_message.try(:thread)
      reply.thread == thread && original_message.thread && original_message.thread == thread
    end

    def fetch_uploads(contract:, guardian:, **)
      return [] if !SiteSetting.chat_allow_uploads
      guardian.user.uploads.where(id: contract.upload_ids)
    end

    def instantiate_message(channel:, guardian:, contract:, uploads:, thread:, reply:, **)
      channel.chat_messages.new(
        user: guardian.user,
        last_editor: guardian.user,
        in_reply_to: reply,
        message: contract.message,
        uploads: uploads,
        thread: thread,
      )
    end

    def save_message(message:, **)
      message.cook
      message.save!
      message.create_mentions
    end

    def create_webhook_event(contract:, message:, **)
      return if contract.incoming_chat_webhook.blank?
      message.create_chat_webhook_event(incoming_chat_webhook: contract.incoming_chat_webhook)
    end

    def create_thread(message:, contract:, original_message:, **)
      return if message.in_reply_to.blank?
      return if message.in_thread? && contract.staged_thread_id.blank?
      message.in_reply_to.thread =
        original_message.thread ||
          Chat::Thread.create!(
            original_message: message.in_reply_to,
            original_message_user: message.in_reply_to.user,
            channel: message.chat_channel,
          )
      message.in_reply_to.save
      message.thread = message.in_reply_to.thread
      message.save

      # NOTE: We intentionally do not try to correct thread IDs within the chain
      # if they are incorrect, and only set the thread ID of messages where the
      # thread ID is NULL. In future we may want some sync/background job to correct
      # any inconsistencies.
      DB.exec(<<~SQL)
        WITH RECURSIVE thread_updater AS (
          SELECT cm.id, cm.in_reply_to_id
          FROM chat_messages cm
          WHERE cm.in_reply_to_id IS NULL AND cm.id = #{original_message.id}

          UNION ALL

          SELECT cm.id, cm.in_reply_to_id
          FROM chat_messages cm
          JOIN thread_updater ON cm.in_reply_to_id = thread_updater.id
        )
        UPDATE chat_messages
        SET thread_id = #{message.thread.id}
        FROM thread_updater
        WHERE thread_id IS NULL AND chat_messages.id = thread_updater.id
      SQL

      if message.chat_channel.threading_enabled?
        Chat::Publisher.publish_thread_created!(
          message.chat_channel,
          message.in_reply_to,
          message.in_reply_to.thread.id,
          contract.staged_thread_id,
        )
      end
    end

    def delete_drafts(channel:, guardian:, **)
      Chat::Draft.where(user: guardian.user, chat_channel: channel).destroy_all
    end

    def post_process_thread(thread:, message:, guardian:, **)
      thread ||= message.thread
      return if thread.blank?

      thread.update!(last_message: message)
      thread.increment_replies_count_cache
      thread.add(guardian.user).update!(last_read_message: message)
      thread.add(thread.original_message_user) if thread.original_message_user != guardian.user
    end

    def update_channel_last_message(channel:, message:, **)
      return if message.thread_reply?
      channel.update!(last_message: message)
    end

    def publish_new_message(channel:, message:, contract:, guardian:, **)
      Chat::Publisher.publish_new!(
        channel,
        message,
        contract.staged_id,
        staged_thread_id: contract.staged_thread_id,
      )
      Jobs.enqueue(Jobs::Chat::ProcessMessage, { chat_message_id: message.id })
      Chat::Notifier.notify_new(chat_message: message, timestamp: message.created_at)
      DiscourseEvent.trigger(:chat_message_created, message, channel, guardian.user)
    end

    def update_membership_last_read(channel_membership:, message:, **)
      return if message.thread_id
      channel_membership.update!(last_read_message: message)
    end

    def process_direct_message_channel(channel_membership:, **)
      Chat::Action::PublishAndFollowDirectMessageChannel.call(
        channel_membership: channel_membership,
      )
    end

    def publish_user_tracking_state(message:, channel:, channel_membership:, guardian:, **)
      Chat::Publisher.publish_user_tracking_state!(
        guardian.user,
        channel,
        message.in_thread? ? channel_membership.last_read_message : message,
      )
    end
  end
end
