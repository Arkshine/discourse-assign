require 'rails_helper'

RSpec.describe TopicListSerializer do
  let(:user) { Fabricate(:user) }

  let(:private_message_topic) do
    Fabricate(:private_message_topic,
      posts: [Fabricate(:post)],
      topic_allowed_users: [
        Fabricate.build(:topic_allowed_user, user: user)
      ]
    )
  end

  let(:assigned_topic) do
    topic = Fabricate(:private_message_topic,
      posts: [Fabricate(:post)],
      topic_allowed_users: [
        Fabricate.build(:topic_allowed_user, user: user)
      ]
    )

    TopicAssigner.new(topic, user).assign(user)
    topic
  end

  let(:guardian) { Guardian.new(user) }
  let(:serializer) { TopicListSerializer.new(topic_list, scope: guardian) }

  before do
    SiteSetting.assign_enabled = true
  end

  describe '#assigned_messages_count' do
    let(:topic_list) do
      TopicQuery.new(user, assigned: user.username).list_private_messages_assigned(user)
    end

    before do
      assigned_topic
    end

    it 'should include right attribute' do
      expect(serializer.as_json[:topic_list][:assigned_messages_count])
        .to eq(1)
    end

    describe 'viewing another user' do
      describe 'as a staff' do
        let(:guardian) { Guardian.new(Fabricate(:admin)) }

        it 'should include the right attribute' do
          expect(serializer.as_json[:topic_list][:assigned_messages_count])
            .to eq(1)
        end
      end

      describe 'as a normal user' do
        let(:guardian) { Guardian.new(Fabricate(:user)) }

        it 'should not include the attribute' do
          expect(serializer.as_json[:topic_list][:assigned_messages_count])
            .to eq(nil)
        end
      end
    end
  end
end