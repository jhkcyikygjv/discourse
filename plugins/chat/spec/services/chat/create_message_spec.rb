# frozen_string_literal: true

RSpec.describe Chat::CreateMessage do
  describe Chat::CreateMessage::Contract, type: :model do
    it { is_expected.to validate_presence_of :chat_channel_id }
    it { is_expected.to validate_presence_of :message }
  end

  describe ".call" do
    subject(:result) { described_class.call(params) }

    fab!(:user) { Fabricate(:user) }
    fab!(:other_user) { Fabricate(:user) }
    fab!(:channel) { Fabricate(:chat_channel, threading_enabled: true) }
    fab!(:thread) { Fabricate(:chat_thread, channel: channel) }
    fab!(:upload) { Fabricate(:upload, user: user) }
    fab!(:draft) { Fabricate(:chat_draft, user: user, chat_channel: channel) }

    let(:guardian) { Guardian.new(user) }
    let(:content) { "A new message @#{other_user.username_lower}" }
    let(:params) do
      { guardian: guardian, chat_channel_id: channel.id, message: content, upload_ids: [upload.id] }
    end
    let(:message) { result[:message].reload }

    context "when user is silenced" do
      before { UserSilencer.new(user).silence }

      it { is_expected.to fail_a_policy(:no_silenced_user) }
    end

    context "when user is not silenced" do
      context "when mandatory parameters are missing" do
        before { params[:chat_channel_id] = "" }

        it { is_expected.to fail_a_contract }
      end

      context "when mandatory parameters are present" do
        context "when channel model is not found" do
          before { params[:chat_channel_id] = -1 }

          it { is_expected.to fail_to_find_a_model(:channel) }
        end

        context "when channel model is found" do
          context "when user can't join channel" do
            let(:guardian) { Guardian.new }

            it { is_expected.to fail_a_policy(:allowed_to_join_channel) }
          end

          context "when user can join channel" do
            context "when user can't create a message in the channel" do
              before { channel.closed!(Discourse.system_user) }

              it { is_expected.to fail_a_policy(:allowed_to_create_message_in_channel) }
            end

            context "when user can create a message in the channel" do
              context "when user is not a member of the channel" do
                it { is_expected.to fail_to_find_a_model(:channel_membership) }
              end

              context "when user is a member of the channel" do
                fab!(:existing_message) { Fabricate(:chat_message, chat_channel: channel) }

                let(:membership) { Chat::UserChatChannelMembership.last }

                before do
                  channel.add(user).update!(last_read_message: existing_message)
                  DiscourseEvent.stubs(:trigger)
                end

                context "when message is a reply" do
                  before { params[:in_reply_to_id] = reply_to.id }

                  context "when original message is not part of the channel" do
                    let(:reply_to) { Fabricate(:chat_message) }

                    it { is_expected.to fail_a_policy(:ensure_reply_consistency) }
                  end
                end

                context "when message is not valid" do
                  let(:content) { "a" * (SiteSetting.chat_maximum_message_length + 1) }

                  it { is_expected.to fail_with_an_invalid_model(:message) }
                end

                context "when a thread is provided" do
                  before { params[:thread_id] = thread.id }

                  context "when thread is not part of the provided channel" do
                    let(:thread) { Fabricate(:chat_thread) }

                    it { is_expected.to fail_a_policy(:ensure_valid_thread_for_channel) }
                  end

                  context "when thread is part of the provided channel" do
                    let(:thread) { Fabricate(:chat_thread, channel: channel) }

                    context "when thread does not match original message" do
                      let(:reply_to) { Fabricate(:chat_message, chat_channel: channel) }
                      let!(:another_thread) do
                        Fabricate(:chat_thread, channel: channel, original_message: reply_to)
                      end

                      before { params[:in_reply_to_id] = reply_to.id }

                      it { is_expected.to fail_a_policy(:ensure_thread_matches_parent) }
                    end
                  end
                end

                it "saves the message" do
                  expect { result }.to change { Chat::Message.count }.by(1)
                  expect(message).to have_attributes(message: content)
                end

                it "cooks the message" do
                  expect(message).to be_cooked
                end

                it "creates mentions" do
                  expect { result }.to change { Chat::Mention.count }.by(1)
                end

                context "when coming from a webhook" do
                  let(:incoming_webhook) do
                    Fabricate(:incoming_chat_webhook, chat_channel: channel)
                  end

                  before { params[:incoming_chat_webhook] = incoming_webhook }

                  it "creates a webhook event" do
                    expect { result }.to change { Chat::WebhookEvent.count }.by(1)
                  end
                end

                context "when replying to another message" do
                  fab!(:reply_to) { Fabricate(:chat_message, chat_channel: channel) }
                  fab!(:another_message) { Fabricate(:chat_message, chat_channel: channel) }

                  before do
                    another_message.update!(in_reply_to: reply_to)
                    params[:in_reply_to_id] = reply_to.id
                  end

                  context "when message is not threaded" do
                    fab!(:thread) do
                      Fabricate(:chat_thread, channel: channel, original_message: reply_to)
                    end

                    context "when original message is threaded" do
                      it "assigns the original message thread" do
                        expect(message).to have_attributes(
                          in_reply_to: an_object_having_attributes(thread: thread),
                          thread: thread,
                        )
                      end
                    end

                    context "when original message is not threaded" do
                      let(:new_thread) { Chat::Thread.last }

                      before { thread.destroy! }

                      it "creates a new thread" do
                        expect { result }.to change { Chat::Thread.count }.by(1)
                        expect(message).to have_attributes(
                          in_reply_to: an_object_having_attributes(thread: new_thread),
                          thread: new_thread,
                        )
                      end
                    end

                    context "when threading is enabled in channel" do
                      it "publishes the assigned thread" do
                        Chat::Publisher.expects(:publish_thread_created!).with(
                          channel,
                          reply_to,
                          thread.id,
                          nil,
                        )
                        result
                      end
                    end

                    it "fixes missing threads in the chain of messages" do
                      expect { result }.to change { another_message.reload.thread }.to thread
                    end
                  end
                end

                it "attaches uploads" do
                  expect(message.uploads).to match_array(upload)
                end

                it "deletes drafts" do
                  expect { result }.to change { Chat::Draft.count }.by(-1)
                end

                context "when message is threaded" do
                  let(:thread) { Fabricate(:chat_thread, channel: channel) }
                  let(:thread_membership) { Chat::UserChatThreadMembership.find_by(user: user) }
                  let(:original_user) { thread.original_message_user }

                  before do
                    params[:thread_id] = thread.id
                    Chat::UserChatThreadMembership.where(user: original_user).delete_all
                  end

                  it "increments the replies count" do
                    expect { result }.to change { thread.reload.replies_count_cache }.by(1)
                  end

                  it "adds current user to the thread" do
                    expect { result }.to change {
                      Chat::UserChatThreadMembership.where(thread: thread, user: user).count
                    }.by(1)
                  end

                  it "sets last_read_message on the thread membership" do
                    result
                    expect(thread_membership.last_read_message).to eq message
                  end

                  it "adds original message user to the thread" do
                    expect { result }.to change {
                      Chat::UserChatThreadMembership.where(
                        thread: thread,
                        user: original_user,
                      ).count
                    }.by(1)
                  end
                end

                it "publishes the new message" do
                  Chat::Publisher.expects(:publish_new!).with(
                    channel,
                    instance_of(Chat::Message),
                    nil,
                    staged_thread_id: nil,
                  )
                  result
                end

                it "enqueues a job to process message" do
                  result
                  expect_job_enqueued(
                    job: Jobs::Chat::ProcessMessage,
                    args: {
                      chat_message_id: message.id,
                    },
                  )
                end

                it "notifies the new message" do
                  result
                  expect_job_enqueued(
                    job: Jobs::Chat::SendMessageNotifications,
                    args: {
                      chat_message_id: message.id,
                      timestamp: message.created_at.iso8601(6),
                      reason: "new",
                    },
                  )
                end

                it "triggers a Discourse event" do
                  DiscourseEvent.expects(:trigger).with(
                    :chat_message_created,
                    instance_of(Chat::Message),
                    channel,
                    user,
                  )
                  result
                end

                context "when message is not threaded" do
                  it "updates membership last_read_message attribute" do
                    expect { result }.to change { membership.reload.last_read_message }
                  end

                  it "updates channel last_message attribute" do
                    result
                    expect(channel.reload.last_message).to eq message
                  end
                end

                it "processes the direct message channel" do
                  Chat::Action::PublishAndFollowDirectMessageChannel.expects(:call).with(
                    channel: channel,
                    guardian: guardian,
                  )
                  result
                end

                context "when message is threaded" do
                  let(:thread) { Fabricate(:chat_thread, channel: channel) }

                  before { params[:thread_id] = thread.id }

                  it "publishes user tracking state" do
                    Chat::Publisher.expects(:publish_user_tracking_state!).with(
                      user,
                      channel,
                      existing_message,
                    )
                    result
                  end

                  it "doesn't update channel last_message attribute" do
                    expect { result }.not_to change { channel.reload.last_message }
                  end

                  it "updates thread last_message attribute" do
                    result
                    expect(thread.reload.last_message).to eq message
                  end
                end

                context "when message is not threaded" do
                  it "publishes user tracking state" do
                    Chat::Publisher
                      .expects(:publish_user_tracking_state!)
                      .with(user, channel, existing_message)
                      .never
                    Chat::Publisher.expects(:publish_user_tracking_state!).with(
                      user,
                      channel,
                      instance_of(Chat::Message),
                    )
                    result
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
