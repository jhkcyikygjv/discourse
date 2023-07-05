# frozen_string_literal: true

module Chat
  module Action
    class PublishAndFollowDirectMessageChannel
      attr_reader :channel, :guardian

      def self.call(...)
        new(...).call
      end

      def initialize(channel:, guardian:)
        @channel = channel
        @guardian = guardian
      end

      def call
        return unless channel.direct_message_channel?
        return if users_allowing_communication.none?

        Chat::Publisher.publish_new_channel(channel, users_allowing_communication)
        channel
          .user_chat_channel_memberships
          .where(user: users_allowing_communication)
          .update_all(following: true)
      end

      private

      def users_allowing_communication
        @users_allowing_communication ||= User.where(id: user_ids).to_a
      end

      def user_ids
        UserCommScreener.new(
          acting_user: guardian.user,
          target_user_ids:
            channel.user_chat_channel_memberships.where(following: false).pluck(:user_id),
        ).allowing_actor_communication
      end
    end
  end
end
