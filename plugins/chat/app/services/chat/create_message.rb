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
    model :thread, optional: true
    policy :ensure_valid_thread_for_channel
    policy :ensure_thread_matches_parent
    model :uploads, optional: true
    model :message, :instantiate_message
    transaction do
      step :save_message
      step :post_process_thread
      step :create_webhook_event
      step :delete_drafts
      step :update_channel_last_message
      step :update_membership_last_read
      step :process_direct_message_channel
    end
    step :publish_new_thread
    step :publish_new_message
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
      reply&.chat_channel == channel
    end

    def fetch_thread(contract:, reply:, channel:, **)
      return Chat::Thread.find_by(id: contract.thread_id) if contract.thread_id.present?
      return unless reply
      reply.thread ||
        reply.build_thread(
          original_message: reply,
          original_message_user: reply.user,
          channel: channel,
        )
    end

    def ensure_valid_thread_for_channel(thread:, contract:, channel:, **)
      return true if contract.thread_id.blank?
      thread&.channel == channel
    end

    def ensure_thread_matches_parent(thread:, reply:, **)
      return true unless thread && reply
      reply.thread == thread
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

    def post_process_thread(thread:, message:, guardian:, **)
      return if thread.blank?

      thread.update!(last_message: message)
      thread.increment_replies_count_cache
      thread.add(guardian.user).update!(last_read_message: message)
      thread.add(thread.original_message_user) if thread.original_message_user != guardian.user
    end

    def create_webhook_event(contract:, message:, **)
      return if contract.incoming_chat_webhook.blank?
      message.create_chat_webhook_event(incoming_chat_webhook: contract.incoming_chat_webhook)
    end

    def delete_drafts(channel:, guardian:, **)
      Chat::Draft.where(user: guardian.user, chat_channel: channel).destroy_all
    end

    def update_channel_last_message(channel:, message:, **)
      return if message.thread_reply?
      channel.update!(last_message: message)
    end

    def update_membership_last_read(channel_membership:, message:, **)
      return if message.thread
      channel_membership.update!(last_read_message: message)
    end

    def process_direct_message_channel(channel_membership:, **)
      Chat::Action::PublishAndFollowDirectMessageChannel.call(
        channel_membership: channel_membership,
      )
    end

    def publish_new_thread(reply:, contract:, channel:, thread:, **)
      return if reply.blank?
      return if contract.thread_id.present? && contract.staged_thread_id.blank?
      return unless channel.threading_enabled?
      Chat::Publisher.publish_thread_created!(channel, reply, thread.id, contract.staged_thread_id)
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

    def publish_user_tracking_state(message:, channel:, channel_membership:, guardian:, **)
      Chat::Publisher.publish_user_tracking_state!(
        guardian.user,
        channel,
        message.in_thread? ? channel_membership.last_read_message : message,
      )
    end
  end
end
