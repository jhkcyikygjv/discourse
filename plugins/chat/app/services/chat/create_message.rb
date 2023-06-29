# frozen_string_literal: true

module Chat
  class CreateMessage
    include Service::Base

    policy :no_silenced_user
    contract
    model :channel
    policy :allowed_to_create_direct_message
    policy :allowed_to_create_message_in_channel
    model :chatable
    model :channel_membership
    policy :ensure_reply_consistency
    step :fetch_uploads
    model :message, :instantiate_message
    model :original_message
    step :fetch_thread
    policy :ensure_valid_thread_for_channel
    policy :ensure_thread_matches_parent
    step :save_message
    step :create_webhook_event
    step :create_thread
    step :attach_uploads
    step :delete_drafts
    step :post_process_thread
    step :publish_new_message
    step :update_membership_last_read
    step :direct_message_autofollow
    step :publish

    class Contract
      attribute :chat_channel_id, :string
      attribute :in_reply_to_id, :integer
      attribute :message, :string
      attribute :staged_id, :integer
      attribute :upload_ids, :array
      attribute :thread_id, :integer
      attribute :staged_thread_id, :integer
      attribute :incoming_chat_webhook

      validates :chat_channel_id, presence: true
    end

    private

    def no_silenced_user(guardian:, **)
      !guardian.user.silenced?
    end

    def fetch_channel(contract:, guardian:, **)
      Chat::ChannelFetcher.find_with_access_check(contract.chat_channel_id, guardian)
    end

    def allowed_to_create_direct_message(guardian:, channel:, **)
      return true if !channel.direct_message_channel?
      guardian.can_create_channel_message?(channel) && guardian.can_create_direct_message?
    end

    def allowed_to_create_message_in_channel(guardian:, channel:, **)
      guardian.can_create_channel_message?(channel)
    end

    def fetch_chatable(channel:, **)
      channel.chatable
    end

    def fetch_channel_membership(guardian:, channel:, **)
      Chat::ChannelMembershipManager.new(channel).find_for_user(guardian.user, following: true)
    end

    def ensure_reply_consistency(channel:, contract:, **)
      return true if contract.in_reply_to_id.blank?
      Chat::Message.find(contract.in_reply_to_id).chat_channel == channel
    end

    def fetch_uploads(contract:, guardian:, **)
      return context[:uploads] = [] if !SiteSetting.chat_allow_uploads
      context[:uploads] = guardian.user.uploads.where(id: contract.upload_ids)
    end

    def instantiate_message(channel:, guardian:, contract:, uploads:, **)
      channel
        .chat_messages
        .new(
          user: guardian.user,
          last_editor: guardian.user,
          in_reply_to_id: contract.in_reply_to_id,
          message: contract.message,
        )
        .tap { _1.validate_message(has_uploads: uploads.present?) }
    end

    def fetch_original_message(contract:, **)
      return true if contract.in_reply_to_id.blank?
      original_message_id = DB.query_single(<<~SQL).last
        WITH RECURSIVE original_message_finder( id, in_reply_to_id )
        AS (
          -- start with the message id we want to find the parents of
          SELECT id, in_reply_to_id
          FROM chat_messages
          WHERE id = #{contract.in_reply_to_id}

          UNION ALL

          -- get the chain of direct parents of the message
          -- following in_reply_to_id
          SELECT cm.id, cm.in_reply_to_id
          FROM original_message_finder rm
          JOIN chat_messages cm ON rm.in_reply_to_id = cm.id
        )
        SELECT id FROM original_message_finder

        -- this makes it so only the root parent ID is returned, we can
        -- exclude this to return all parents in the chain
        WHERE in_reply_to_id IS NULL;
      SQL

      Chat::Message.find_by(id: original_message_id)
    end

    def fetch_thread(contract:, **)
      context[:thread] = Chat::Thread.find_by(id: contract.thread_id)
    end

    def ensure_valid_thread_for_channel(thread:, contract:, channel:, **)
      return true if thread.blank? && contract.staged_thread_id.present?
      return true if thread.blank?
      thread.channel == channel
    end

    def ensure_thread_matches_parent(thread:, contract:, original_message:, message:, **)
      return true if thread.blank? && contract.staged_thread_id.present?
      return true if thread.blank?
      message.in_reply_to.thread == thread && original_message.thread &&
        original_message.thread == thread
    end

    def save_message(message:, thread:, **)
      message.thread = thread
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
            original_message: message.reply_to,
            original_message_user: message.in_reply_to.user,
            channel: message.chat_channel,
          )

      if message.chat_channel.threading_enabled?
        Chat::Publisher.publish_thread_created!(
          message.chat_channel,
          message.in_reply_to,
          message.in_reply_to.thread.id,
          contract.staged_thread_id,
        )
      end
      message.thread = message.in_reply_to.thread

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
    end

    def attach_uploads(message:, uploads:, **)
      message.attach_uploads(uploads)
    end

    def delete_drafts(channel:, guardian:, **)
      Chat::Draft.where(user: guardian.user, chat_channel: channel).destroy_all
    end

    def post_process_thread(thread:, message:, guardian:, **)
      thread ||= message.thread
      return if thread.blank?

      thread.increment_replies_count_cache
      thread.add(guardian.user).update!(last_read_message: message)
      thread.add(thread.original_message_user) if thread.original_message_user != guardian.user
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
      channel.touch(:last_message_sent_at)
      DiscourseEvent.trigger(:chat_message_created, message, channel, guardian.user)
    end

    def update_membership_last_read(channel_membership:, message:, **)
      return if message.thread_id
      channel_membership.update!(last_read_message: message)
    end

    def direct_message_autofollow(channel:, guardian:, **)
      return unless channel.direct_message_channel?

      # If any of the channel users is ignoring, muting, or preventing DMs from
      # the current user then we should not auto-follow the channel once again or
      # publish the new channel.
      user_ids_allowing_communication =
        UserCommScreener.new(
          acting_user: guardian.user,
          target_user_ids:
            channel.user_chat_channel_memberships.where(following: false).pluck(:user_id),
        ).allowing_actor_communication

      return if user_ids_allowing_communication.none?
      Chat::Publisher.publish_new_channel(channel, User.where(id: user_ids_allowing_communication))
      channel
        .user_chat_channel_memberships
        .where(user_id: user_ids_allowing_communication)
        .update_all(following: true)
    end

    def publish(message:, channel:, channel_membership:, guardian:, **)
      Chat::Publisher.publish_user_tracking_state!(
        guardian.user,
        channel,
        message.in_thread? ? channel_membership.last_read_message : message,
      )
    end
  end
end
