# frozen_string_literal: true

RSpec.describe Chat::Action::PublishAndFollowDirectMessageChannel do
  describe ".call" do
    subject(:action) { described_class.call(channel: channel, guardian: guardian) }

    fab!(:user) { Fabricate(:user) }

    let(:guardian) { Guardian.new(user) }

    before { channel.add(user) }

    context "when channel is not a direct message one" do
      fab!(:channel) { Fabricate(:chat_channel) }

      it "does not publish anything" do
        Chat::Publisher.expects(:publish_new_channel).never
        action
      end

      it "does not update memberships" do
        expect { action }.not_to change {
          channel.user_chat_channel_memberships.where(following: true).count
        }
      end
    end

    context "when channel is a direct message one" do
      fab!(:channel) { Fabricate(:direct_message_channel) }

      context "when no users allow communication" do
        it "does not publish anything" do
          Chat::Publisher.expects(:publish_new_channel).never
          action
        end

        it "does not update memberships" do
          expect { action }.not_to change {
            channel.user_chat_channel_memberships.where(following: true).count
          }
        end
      end

      context "when at least one user allows communication" do
        let(:users) { channel.user_chat_channel_memberships.where.not(user: user).map(&:user) }

        before { channel.user_chat_channel_memberships.update_all(following: false) }

        it "publishes the channel" do
          Chat::Publisher.expects(:publish_new_channel).with(channel, users)
          action
        end

        it "sets autofollow for these users" do
          expect { action }.to change {
            channel.user_chat_channel_memberships.where(following: true).count
          }.by(2)
        end
      end
    end
  end
end
