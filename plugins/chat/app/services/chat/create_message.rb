# frozen_string_literal: true

module Chat
  class CreateMessage
    include Service::Base

    policy :no_silenced_user
    contract
    model :channel
    model :chatable
    model :channel_membership
    policy :ensure_reply_consistency
    step :create_message
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

      validates :chat_channel_id, presence: true
    end

    private

    def no_silenced_user(guardian:, **)
      !guardian.user.silenced?
    end

    def fetch_channel(contract:, guardian:, **)
      Chat::ChannelFetcher.find_with_access_check(contract.chat_channel_id, guardian)
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

    # TODO: migrate `MessageCreator` here
    def create_message(contract:, channel:, guardian:, **)
      Chat::MessageCreator
        .create(
          chat_channel: channel,
          user: guardian.user,
          in_reply_to_id: contract.in_reply_to_id,
          content: contract.message,
          staged_id: contract.staged_id,
          upload_ids: contract.upload_ids,
          thread_id: contract.thread_id,
          staged_thread_id: contract.staged_thread_id,
        )
        .then do |creator|
          fail!(creator.error) if creator.failed?
          context[:message] = creator.chat_message
        end
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
