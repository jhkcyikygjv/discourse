# frozen_string_literal: true

module Chat
  module Action
    class PostProcessThreadedMessage
      attr_reader :message

      delegate :thread, :user, :in_reply_to, to: :message

      def self.call(...)
        new(...).call
      end

      def initialize(message:)
        @message = message
      end

      def call
        return unless thread

        thread.update!(last_message: message)
        thread.increment_replies_count_cache
        thread.add(user).update!(last_read_message: message)
        thread.add(thread.original_message_user) if thread.original_message_user != user
      end

      private
    end
  end
end
