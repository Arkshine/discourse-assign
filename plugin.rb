# frozen_string_literal: true

# name: discourse-assign
# about: Assign users to topics
# version: 1.0.0
# authors: Sam Saffron
# url: https://github.com/discourse/discourse-assign

enabled_site_setting :assign_enabled

register_asset 'stylesheets/assigns.scss'
register_asset 'stylesheets/mobile/assigns.scss', :mobile

register_svg_icon "user-plus"
register_svg_icon "user-times"

%w[user-plus user-times group-plus group-times].each { |i| register_svg_icon(i) }

load File.expand_path('../lib/discourse_assign/engine.rb', __FILE__)
load File.expand_path('../lib/discourse_assign/helpers.rb', __FILE__)

Discourse::Application.routes.append do
  mount ::DiscourseAssign::Engine, at: "/assign"
  get "topics/private-messages-assigned/:username" => "list#private_messages_assigned", as: "topics_private_messages_assigned", constraints: { username: ::RouteFormat.username }
  get "/topics/messages-assigned/:username" => "list#messages_assigned", constraints: { username: ::RouteFormat.username }, as: "messages_assigned"
  get "/topics/group-topics-assigned/:groupname" => "list#group_topics_assigned", constraints: { username: ::RouteFormat.username }, as: "group_topics_assigned"
  get "/g/:id/assigned" => "groups#index"
  get "/g/:id/assigned/:route_type" => "groups#index"
end

after_initialize do
  require File.expand_path('../jobs/scheduled/enqueue_reminders.rb', __FILE__)
  require File.expand_path('../jobs/regular/remind_user.rb', __FILE__)
  require File.expand_path('../jobs/regular/assign_notification.rb', __FILE__)
  require File.expand_path('../jobs/regular/unassign_notification.rb', __FILE__)
  require 'topic_assigner'
  require 'pending_assigns_reminder'

  # TODO: Drop when Discourse stable 2.8.0 is released
  if respond_to?(:register_group_param)
    register_group_param(:assignable_level)
  end
  if respond_to?(:register_groups_callback_for_users_search_controller_action)
    register_groups_callback_for_users_search_controller_action(:assignable_groups) do |groups, user|
      groups.assignable(user)
    end
  end

  class ::Topic
    has_one :assignment, dependent: :destroy
  end

  class ::Group
    scope :assignable, ->(user) {
      where("assignable_level in (:levels) OR
          (
            assignable_level = #{ALIAS_LEVELS[:members_mods_and_admins]} AND id in (
            SELECT group_id FROM group_users WHERE user_id = :user_id)
          ) OR (
            assignable_level = #{ALIAS_LEVELS[:owners_mods_and_admins]} AND id in (
            SELECT group_id FROM group_users WHERE user_id = :user_id AND owner IS TRUE)
          )", levels: alias_levels(user), user_id: user && user.id)
    }
  end

  frequency_field = PendingAssignsReminder::REMINDERS_FREQUENCY
  register_editable_user_custom_field frequency_field
  User.register_custom_field_type frequency_field, :integer
  DiscoursePluginRegistry.serialized_current_user_fields << frequency_field
  add_to_serializer(:user, :reminders_frequency) do
    RemindAssignsFrequencySiteSettings.values
  end

  add_to_serializer(:group_show, :assignment_count) do
    Topic
      .joins(<<~SQL)
        JOIN assignments a
        ON topics.id = a.topic_id AND a.assigned_to_id IS NOT NULL
      SQL
      .where(<<~SQL, group_id: object.id)
        (
          a.assigned_to_type = 'User' AND a.assigned_to_id IN (
            SELECT group_users.user_id
            FROM group_users
            WHERE group_id = :group_id
          )
        ) OR (
          a.assigned_to_type = 'Group' AND a.assigned_to_id = :group_id
        )
      SQL
      .where("topics.deleted_at IS NULL")
      .count
  end

  add_to_serializer(:group_show, 'include_assignment_count?') do
    scope.can_assign?
  end

  add_to_serializer(:group_show, :assignable_level) do
    object.assignable_level
  end

  add_to_serializer(:group_show, :can_show_assigned_tab?) do
    object.can_show_assigned_tab?
  end

  add_model_callback(UserCustomField, :before_save) do
    self.value = self.value.to_i if self.name == frequency_field
  end

  add_class_method(:group, :assign_allowed_groups) do
    allowed_groups = SiteSetting.assign_allowed_on_groups.split('|')
    where(id: allowed_groups)
  end

  add_to_class(:user, :can_assign?) do
    @can_assign ||=
      begin
        return true if admin?
        allowed_groups = SiteSetting.assign_allowed_on_groups.split('|').compact
        allowed_groups.present? && groups.where(id: allowed_groups).exists? ?
          :true : :false
      end
    @can_assign == :true
  end

  add_to_class(:group, :can_show_assigned_tab?) do
    allowed_group_ids = SiteSetting.assign_allowed_on_groups.split("|")

    group_has_disallowed_users = DB.query_single(<<~SQL, allowed_group_ids: allowed_group_ids, current_group_id: self.id)[0]
      SELECT EXISTS(
        SELECT 1 FROM users
        JOIN group_users current_group_users
          ON current_group_users.user_id=users.id
          AND current_group_users.group_id = :current_group_id
        LEFT JOIN group_users allowed_group_users
          ON allowed_group_users.user_id=users.id
          AND allowed_group_users.group_id IN (:allowed_group_ids)
        WHERE allowed_group_users.user_id IS NULL
      )
    SQL

    !group_has_disallowed_users
  end

  add_to_class(:guardian, :can_assign?) { user && user.can_assign? }

  add_class_method(:user, :assign_allowed) do
    allowed_groups = SiteSetting.assign_allowed_on_groups.split('|')
    where("users.admin OR users.id IN (
      SELECT user_id FROM group_users
      INNER JOIN groups ON group_users.group_id = groups.id
      WHERE groups.id IN (?)
    )", allowed_groups)
  end

  add_model_callback(Group, :before_update) do
    if name_changed?
      SiteSetting.assign_allowed_on_groups = SiteSetting.assign_allowed_on_groups.gsub(name_was, name)
    end
  end

  add_model_callback(Group, :before_destroy) do
    new_setting = SiteSetting.assign_allowed_on_groups.gsub(/#{id}[|]?/, '')
    new_setting = new_setting.chomp('|') if new_setting.ends_with?('|')
    SiteSetting.assign_allowed_on_groups = new_setting
  end

  on(:assign_topic) do |topic, user, assigning_user, force|
    if force || !Assignment.exists?(topic: topic)
      TopicAssigner.new(topic, assigning_user).assign(user)
    end
  end

  on(:unassign_topic) do |topic, unassigning_user|
    TopicAssigner.new(topic, unassigning_user).unassign
  end

  Site.preloaded_category_custom_fields << "enable_unassigned_filter"

  BookmarkQuery.on_preload do |bookmarks, bookmark_query|
    if SiteSetting.assign_enabled?
      topics = bookmarks.map(&:topic)
      assignments = Assignment.strict_loading.where(topic: topics).includes(:assigned_to).index_by(&:topic_id)

      topics.each do |topic|
        assigned_to = assignments[topic.id]&.assigned_to
        topic.preload_assigned_to(assigned_to)
      end
    end
  end

  TopicList.on_preload do |topics, topic_list|
    if SiteSetting.assign_enabled?
      can_assign = topic_list.current_user && topic_list.current_user.can_assign?
      allowed_access = SiteSetting.assigns_public || can_assign

      if allowed_access && topics.length > 0
        assignments = Assignment.strict_loading.where(topic: topics)
        assignments_map = assignments.index_by(&:topic_id)

        user_ids = assignments.filter { |assignment| assignment.assigned_to_type == "User" }.map(&:assigned_to_id)
        users_map = User.where(id: user_ids).select(UserLookup.lookup_columns).index_by(&:id)

        group_ids = assignments.filter { |assignment| assignment.assigned_to_type == "Group" }.map(&:assigned_to_id)
        groups_map = Group.where(id: group_ids).index_by(&:id)

        topics.each do |topic|
          assignment = assignments_map[topic.id]
          assigned_to = users_map[assignment.assigned_to_id] if assignment&.assigned_to_type == "User"
          assigned_to = groups_map[assignment.assigned_to_id] if assignment&.assigned_to_type == "Group"
          topic.preload_assigned_to(assigned_to)
        end
      end
    end
  end

  Search.on_preload do |results, search|
    if SiteSetting.assign_enabled?
      can_assign = search.guardian&.can_assign?
      allowed_access = SiteSetting.assigns_public || can_assign

      if allowed_access && results.posts.length > 0
        topics = results.posts.map(&:topic)
        assignments = Assignment.strict_loading.where(topic: topics).includes(:assigned_to).index_by(&:topic_id)

        results.posts.each do |post|
          assigned_to = assignments[post.topic.id]&.assigned_to
          post.topic.preload_assigned_to(assigned_to)
        end
      end
    end
  end

  # TopicQuery
  require_dependency 'topic_query'
  TopicQuery.add_custom_filter(:assigned) do |results, topic_query|
    name = topic_query.options[:assigned]
    next results if name.blank?

    next results if !topic_query.guardian.can_assign? && !SiteSetting.assigns_public

    if name == "nobody"
      next results
        .joins("LEFT JOIN assignments a ON a.topic_id = topics.id")
        .where("a.assigned_to_id IS NULL")
    end

    if name == "*"
      next results
        .joins("JOIN assignments a ON a.topic_id = topics.id")
        .where("a.assigned_to_id IS NOT NULL")
    end

    user_id = topic_query.guardian.user.id if name == "me"
    user_id ||= User.where(username_lower: name.downcase).pluck_first(:id)

    if user_id
      next results
        .joins("JOIN assignments a ON a.topic_id = topics.id")
        .where("a.assigned_to_id = ? AND a.assigned_to_type = 'User'", user_id)
    end

    group_id = Group.where(name: name.downcase).pluck_first(:id)

    if group_id
      next results
        .joins("JOIN assignments a ON a.topic_id = topics.id")
        .where("a.assigned_to_id = ? AND a.assigned_to_type = 'Group'", group_id)
    end

    next results
  end

  add_to_class(:topic_query, :list_messages_assigned) do |user|
    list = default_results(include_pms: true)

    list = list.where(<<~SQL, user_id: user.id)
      topics.id IN (
        SELECT topic_id FROM assignments
        LEFT JOIN group_users ON group_users.user_id = :user_id
        WHERE
          assigned_to_id = :user_id AND assigned_to_type = 'User'
          OR
          assigned_to_id IN (group_users.group_id) AND assigned_to_type = 'Group'
      )
    SQL

    create_list(:assigned, { unordered: true }, list)
  end

  add_to_class(:topic_query, :list_group_topics_assigned) do |group|
    list = default_results(include_pms: true)

    list = list.where(<<~SQL, group_id: group.id)
      topics.id IN (
        SELECT topic_id FROM assignments
        WHERE (
          assigned_to_id IN (SELECT user_id from group_users where group_id = :group_id) AND assigned_to_type = 'User'
        ) OR (
          assigned_to_id = :group_id AND assigned_to_type = 'Group'
        )
      )
    SQL

    create_list(:assigned, { unordered: true }, list)
  end

  add_to_class(:topic_query, :list_private_messages_assigned) do |user|
    list = private_messages_assigned_query(user)
    create_list(:private_messages, {}, list)
  end

  add_to_class(:topic_query, :private_messages_assigned_query) do |user|
    list = private_messages_for(user, :all)

    group_ids = user.groups.map(&:id)

    list = list.where(<<~SQL, user_id: user.id, group_ids: group_ids)
      topics.id IN (
        SELECT topic_id FROM assignments WHERE
        (assigned_to_id = :user_id AND assigned_to_type = 'User') OR
        (assigned_to_id IN (:group_ids) AND assigned_to_type = 'Group')
      )
    SQL
  end

  # ListController
  require_dependency 'list_controller'
  class ::ListController
    generate_message_route(:private_messages_assigned)
  end

  add_to_class(:list_controller, :messages_assigned) do
    user = User.find_by_username(params[:username])
    raise Discourse::NotFound unless user
    raise Discourse::InvalidAccess unless current_user.can_assign?

    list_opts = build_topic_list_options
    list = generate_list_for("messages_assigned", user, list_opts)

    list.more_topics_url = construct_url_with(:next, list_opts)
    list.prev_topics_url = construct_url_with(:prev, list_opts)

    respond_with_list(list)
  end

  add_to_class(:list_controller, :group_topics_assigned) do
    group = Group.find_by("name = ?", params[:groupname])
    guardian.ensure_can_see_group_members!(group)

    raise Discourse::NotFound unless group
    raise Discourse::InvalidAccess unless current_user.can_assign?
    raise Discourse::InvalidAccess unless group.can_show_assigned_tab?

    list_opts = build_topic_list_options
    list = generate_list_for("group_topics_assigned", group, list_opts)

    list.more_topics_url = construct_url_with(:next, list_opts)
    list.prev_topics_url = construct_url_with(:prev, list_opts)

    respond_with_list(list)
  end

  # Topic
  add_to_class(:topic, :assigned_to) do
    return @assigned_to if defined?(@assigned_to)
    @assigned_to = assignment&.assigned_to
  end

  add_to_class(:topic, :preload_assigned_to) do |assigned_to|
    @assigned_to = assigned_to
  end

  # TopicList serializer
  add_to_serializer(:topic_list, :assigned_messages_count) do
    TopicQuery.new(object.current_user, guardian: scope, limit: false)
      .private_messages_assigned_query(object.current_user)
      .count
  end

  add_to_serializer(:topic_list, 'include_assigned_messages_count?') do
    options = object.instance_variable_get(:@opts)

    if assigned_user = options.dig(:assigned)
      scope.can_assign? ||
        assigned_user.downcase == scope.current_user&.username_lower
    end
  end

  # TopicView serializer
  add_to_serializer(:topic_view, :assigned_to_user, false) do
    DiscourseAssign::Helpers.build_assigned_to_user(object.topic.assigned_to, object.topic)
  end

  add_to_serializer(:topic_view, :include_assigned_to_user?) do
    (SiteSetting.assigns_public || scope.can_assign?) && object.topic.assigned_to&.is_a?(User)
  end

  add_to_serializer(:topic_view, :assigned_to_group, false) do
    DiscourseAssign::Helpers.build_assigned_to_group(object.topic.assigned_to, object.topic)
  end

  add_to_serializer(:topic_view, :include_assigned_to_group?) do
    (SiteSetting.assigns_public || scope.can_assign?) && object.topic.assigned_to&.is_a?(Group)
  end

  # TopicListItem serializer
  add_to_serializer(:topic_list_item, :assigned_to_user) do
    BasicUserSerializer.new(object.assigned_to, scope: scope, root: false).as_json
  end

  add_to_serializer(:topic_list_item, :include_assigned_to_user?) do
    (SiteSetting.assigns_public || scope.can_assign?) && object.assigned_to&.is_a?(User)
  end

  add_to_serializer(:topic_list_item, :assigned_to_group) do
    BasicGroupSerializer.new(object.assigned_to, scope: scope, root: false).as_json
  end

  add_to_serializer(:topic_list_item, :include_assigned_to_group?) do
    (SiteSetting.assigns_public || scope.can_assign?) && object.assigned_to&.is_a?(Group)
  end

  # SearchTopicListItem serializer
  add_to_serializer(:search_topic_list_item, :assigned_to_user, false) do
    object.assigned_to
  end

  add_to_serializer(:search_topic_list_item, 'include_assigned_to_user?') do
    (SiteSetting.assigns_public || scope.can_assign?) && object.assigned_to&.is_a?(User)
  end

  add_to_serializer(:search_topic_list_item, :assigned_to_group, false) do
    object.assigned_to
  end

  add_to_serializer(:search_topic_list_item, 'include_assigned_to_group?') do
    (SiteSetting.assigns_public || scope.can_assign?) && object.assigned_to&.is_a?(Group)
  end

  # TopicsBulkAction
  TopicsBulkAction.register_operation("assign") do
    if @user.can_assign?
      assign_user = User.find_by_username(@operation[:username])
      topics.each do |t|
        TopicAssigner.new(t, @user).assign(assign_user)
      end
    end
  end

  TopicsBulkAction.register_operation("unassign") do
    if @user.can_assign?
      topics.each do |t|
        if guardian.can_assign?
          TopicAssigner.new(t, @user).unassign
        end
      end
    end
  end

  register_permitted_bulk_action_parameter :username

  # UserBookmarkSerializer
  add_to_serializer(:user_bookmark, :assigned_to_user, false) do
    topic.assigned_to
  end

  add_to_serializer(:user_bookmark, 'include_assigned_to_user?') do
    (SiteSetting.assigns_public || scope.can_assign?) && topic.assigned_to&.is_a?(User)
  end

  add_to_serializer(:user_bookmark, :assigned_to_group, false) do
    topic.assigned_to
  end

  add_to_serializer(:user_bookmark, 'include_assigned_to_group?') do
    (SiteSetting.assigns_public || scope.can_assign?) && topic.assigned_to&.is_a?(Group)
  end

  # CurrentUser serializer
  add_to_serializer(:current_user, :can_assign) do
    object.can_assign?
  end

  # FlaggedTopic serializer
  add_to_serializer(:flagged_topic, :assigned_to_user) do
    DiscourseAssign::Helpers.build_assigned_to_user(object.assigned_to, object)
  end

  add_to_serializer(:flagged_topic, :include_assigned_to_user?) do
    object.assigned_to&.is_a?(User)
  end

  add_to_serializer(:flagged_topic, :assigned_to_group) do
    DiscourseAssign::Helpers.build_assigned_to_group(object.assigned_to, object)
  end

  add_to_serializer(:flagged_topic, :include_assigned_to_group?) do
    object.assigned_to&.is_a?(Group)
  end

  # Reviewable
  add_custom_reviewable_filter(
    [
      :assigned_to,
      Proc.new do |results, value|
        results.joins(<<~SQL
          INNER JOIN posts p ON p.id = target_id
          INNER JOIN topics t ON t.id = p.topic_id
          INNER JOIN assignments a ON a.topic_id = t.id AND a.assigned_to_type == 'User'
          INNER JOIN users u ON u.id = a.assigned_to_id
        SQL
        )
        .where(target_type: Post.name)
        .where('u.username = ?', value)
      end
    ]
  )

  # TopicTrackingState
  add_class_method(:topic_tracking_state, :publish_assigned_private_message) do |topic, user_id|
    return unless topic.private_message?

    MessageBus.publish(
      "/private-messages/assigned",
      { topic_id: topic.id },
      user_ids: [user_id]
    )
  end

  # Event listeners
  on(:post_created) do |post|
    ::TopicAssigner.auto_assign(post, force: true)
  end

  on(:post_edited) do |post, topic_changed|
    ::TopicAssigner.auto_assign(post, force: true)
  end

  on(:topic_status_updated) do |topic, status, enabled|
    if SiteSetting.unassign_on_close && (status == 'closed' || status == 'autoclosed') && enabled
      assigner = ::TopicAssigner.new(topic, Discourse.system_user)
      assigner.unassign(silent: true)
    end
  end

  on(:move_to_inbox) do |info|
    topic = info[:topic]
    assigned_to_id = topic.assignment&.assigned_to_id
    assigned_to_type = topic.assignment&.assigned_to_type

    if info[:user]&.id == assigned_to_id && assigned_to_type == "User"
      TopicTrackingState.publish_assigned_private_message(topic, assigned_to_id)
    end

    next if !SiteSetting.unassign_on_group_archive
    next if !info[:group]

    previous_assigned_to_id = topic.custom_fields["prev_assigned_to_id"]&.to_i
    next if !previous_assigned_to_id

    assigned_type = topic.custom_fields["prev_assigned_to_type"]
    assigned_class = assigned_type == "Group" ? Group : User
    previous_assigned_to = assigned_class.find_by(id: previous_assigned_to_id)

    if previous_assigned_to
      assigner = TopicAssigner.new(topic, Discourse.system_user)
      assigner.assign(previous_assigned_to, silent: true)
    end
  end

  on(:archive_message) do |info|
    topic = info[:topic]
    next if !topic.assignment

    assigned_to_id = topic.assignment.assigned_to_id
    assigned_to_type = topic.assignment.assigned_to_type

    if info[:user]&.id == assigned_to_id && assigned_to_type == "User"
      TopicTrackingState.publish_assigned_private_message(topic, assigned_to_id)
    end

    next if !SiteSetting.unassign_on_group_archive
    next if !info[:group]

    if assigned_to = topic.assignment
      topic.custom_fields["prev_assigned_to_id"] = assigned_to.id
      topic.custom_fields["prev_assigned_to_type"] = assigned_to.class
      topic.save!

      assigner = TopicAssigner.new(topic, Discourse.system_user)
      assigner.unassign(silent: true)
    end
  end

  on(:user_removed_from_group) do |user, group|
    assign_allowed_groups = SiteSetting.assign_allowed_on_groups.split('|').map(&:to_i)

    if assign_allowed_groups.include?(group.id)
      groups = GroupUser.where(user: user).pluck(:group_id)

      if (groups & assign_allowed_groups).empty?
        topics = Topic.joins(:assignment).where('assignments.assigned_to_id = ?', user.id)

        topics.each do |topic|
          TopicAssigner.new(topic, Discourse.system_user).unassign
        end
      end
    end
  end

  class ::WebHook
    def self.enqueue_assign_hooks(event, payload)
      if active_web_hooks('assign').exists?
        WebHook.enqueue_hooks(:assign, event,
          payload: payload
        )
      end
    end
  end

  register_search_advanced_filter(/in:assigned/) do |posts|
    if @guardian.can_assign?
      posts.where(<<~SQL)
        topics.id IN (
          SELECT a.topic_id FROM assignments a
        )
      SQL
    end
  end

  register_search_advanced_filter(/in:unassigned/) do |posts|
    if @guardian.can_assign?
      posts.where(<<~SQL)
        topics.id NOT IN (
          SELECT a.topic_id FROM assignments a
        )
      SQL
    end
  end

  register_search_advanced_filter(/assigned:(.+)$/) do |posts, match|
    if @guardian.can_assign?
      if user_id = User.find_by_username(match)&.id
        posts.where(<<~SQL, user_id)
          topics.id IN (
            SELECT a.topic_id FROM assignments a WHERE a.assigned_to_id = ? AND a.assigned_to_type = 'User'
          )
        SQL
      elsif group_id = Group.find_by_name(match)&.id
        posts.where(<<~SQL, group_id)
          topics.id IN (
            SELECT a.topic_id FROM assignments a WHERE a.assigned_to_id = ? AND a.assigned_to_type = 'Group'
          )
        SQL
      end
    end
  end

  if defined?(DiscourseAutomation)
    require 'random_assign_utils'

    add_automation_scriptable('random_assign') do
      field :assignees_group, component: :group
      field :assigned_topic, component: :text
      field :minimum_time_between_assignments, component: :text
      field :in_working_hours, component: :boolean

      version 1

      triggerables %i[point_in_time recurring]

      script do |context, fields|
        next unless SiteSetting.assign_enabled?

        next unless topic_id = fields.dig('assigned_topic', 'value')
        next unless topic = Topic.find_by(id: topic_id)

        next unless group_id = fields.dig('assignees_group', 'value')
        next unless group = Group.find_by(id: group_id)

        min_hours = fields.dig('minimum_time_between_assignments', 'value')
        if min_hours && TopicCustomField
            .where(name: 'assigned_to_id', topic_id: topic_id)
            .where('created_at < ?', min_hours.to_i.hours.ago)
            .exists?
          next
        end

        users_on_holiday = Set.new(
          User
            .where(id:
              UserCustomField
              .where(name: 'on_holiday', value: 't')
              .pluck(:user_id)
            ).pluck(:id)
        )

        group_users_ids = group
          .group_users
          .joins(:user)
          .pluck('users.id')
          .reject { |user_id| users_on_holiday.include?(user_id) }

        if group_users_ids.empty?
          RandomAssignUtils.no_one!(topic_id, group.name)
          next
        end

        last_assignees_ids = UserAction
          .joins(:user)
          .where(action_type: UserAction::ASSIGNED, target_topic_id: topic_id)
          .where('user_actions.created_at > ?', 6.months.ago)
          .order(created_at: :desc)
          .limit(group_users_ids.length)
          .pluck('users.id')
          .uniq

        users_ids = group_users_ids - last_assignees_ids
        if users_ids.blank?
          recently_assigned_users_ids = UserAction
            .joins(:user)
            .where(action_type: UserAction::ASSIGNED, target_topic_id: topic_id)
            .where('user_actions.created_at < ?', 2.weeks.ago)
            .pluck('users.id')
            .uniq
          users_ids = group_users_ids - recently_assigned_users_ids
        end

        if users_ids.blank?
          RandomAssignUtils.no_one!(topic_id, group.name)
          next
        end

        if fields.dig('in_working_hours', 'value')
          assign_to_user_id = users_ids.shuffle.find do |user_id|
            RandomAssignUtils.in_working_hours?(user_id)
          end
        end

        assign_to_user_id ||= users_ids.sample
        if assign_to_user_id.blank?
          RandomAssignUtils.no_one!(topic_id, group.name)
          next
        end

        assign_to = User.find_by(id: assign_to_user_id)
        assign_to && TopicAssigner.new(topic, Discourse.system_user).assign(assign_to)
      end
    end
  end
end
