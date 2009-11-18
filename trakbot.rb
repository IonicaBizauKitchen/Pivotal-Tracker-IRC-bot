require 'optparse'
require 'pp'
require 'yaml'

require 'rubygems'
require 'pivotal-tracker'

require 'chatbot'
require 'common_actions'
require 'user'



options = {
  :channel => 'traktest',
  :full => 'Pivotal Tracker IRC bot',
  :nick => 'trackbot',
  :port => '6667',
  :server => 'irc.freenode.net',
  :logging => :warn,
  :storage_location => '.'
}

optparse = OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options]"

  opts.on('-c', '--channel NAME', 'Specify IRC channel to /join. (test)') {|options[:channel]|}
  opts.on('-f', '--full-name NICK', "Specify the bot\'s IRC full name. (#{options[:full]})") {|options[:full]|}
  opts.on('-n', '--nick NICK', "Specify the bot\'s IRC nick. (#{options[:nick]})") {|options[:nick]|}
  opts.on('-s', '--server HOST', 'Specify IRC server hostname. (irc.freenode.net)') {|options[:server]|}
  opts.on('-p', '--port NUMBER', Integer, 'Specify IRC port number. (6667)') {|options[:port]|}
  opts.on('-l', '--logging LEVEL', [:debug, :info, :warn, :error, :fatal], 'Logging level (debug, info, warn, error, fatal) (warn)') {|options[:logging]|}
  opts.on('-y', '--storage-file FILENAME', 'The directory the bot will use to store its state files in. (.)') {|options[:storage_location]|}

  opts.on_tail('-h', '--help', 'Display this screen') {puts opts; exit}
end

optparse.parse!


class ChoreFinishedError < StandardError; end
class NoSearchError < StandardError; end

class Trakbot < Chatbot
  include CommonActions

  def initialize(options)
    super options[:nick], options[:server], options[:port], options[:full]
    @options = options

    @help = [
      "help: this",
      "token <token>: Teach me your nick's Pivotal Tracker API token",
      "initials [nick] <initials>: Teach me your nick's  (or another nick's) Pivotal Tracker initials",
      "project <id>|<partial name>: Set your current project",
      "projects: List all known projects",
      "story <id|list-index>: Set your current story",
      "story name|estimate <text>: Update the story",
      "story story_type feature|bug|chore|release: Update the story",
      "story current_state unstarted|started|finished|delivered|rejected|accepted: Update the story",
      "comment|note <text>: Add a comment to the story",
      "find <text>: Find stories in the project that match the search criteria in <text>.",
      "list found: List results of the last find (even if it's long).",
      "finished: List finished stories in the project",
      "deliver finished: Deliver (and display) all finished stories",
      "new feature|chore|bug|release <name>: Create a story in the project's Icebox with given name",
      "work [user]: Show what stories [user] is working on (default is you)"
    ]

    @logger.level = eval "Logger::#{options[:logging].to_s.upcase}"

    User.save_location = options[:storage_location]
    User.logger = @logger

    # The channel to join.
    add_room('#' + options[:channel])

    nick = options[:nick]

    add_actions({
      %w[token (\S+)].to_regexp =>
      lambda do |nick, event, match|
        user = User.for_nick nick
        user.token = match[1]
        reply event, one_of(["Got it, #{nick}.", "Gotcha, #{nick}.", "All righty, #{nick}!"])
      end,

      %w[initials (\w+)].to_regexp =>
      lambda do |nick, event, match|
        user = User.for_nick nick
        user.initials = match[1]
        reply event, "Got it, #{nick}."
      end,

      %w[initials (\w+) (\w+)].to_regexp =>
      lambda do |nick, event, match|
        user = User.for_nick match[1]
        user.initials = match[2]
        reply event, "Got it, #{nick}."
      end,

      %w[(?:new|add) (feature|chore|bug|release) (.+)].to_regexp =>
      lambda do |nick, event, match|
        user = User.for_nick nick
        story = user.create_story :name => match[2], :story_type => match[1]
        reply event, "Added story #{story.id}"
      end,

      %w[project (\d+)].to_regexp =>
      lambda do |nick, event, match|
        user = User.for_nick nick
        user.current_project_id = match[1]
        reply event, "#{nick}, you're on #{user.current_project.name}."
      end,

      %w[project (.*[a-z].*)].to_regexp =>
      lambda do |nick, event, match|
        user = User.for_nick nick
        projects = user.projects.select{|p| p.name.downcase.include? match[1].downcase}

        if projects.empty?
          reply event, "#{nick}, I couldn't find a project with '#{match[1]}' in its name."
        elsif projects.size > 1
          reply event, "#{nick}, you'll need to be a bit more specific. I found #{projects.map{|p| p.name} * ', '}."
        else
          user.current_project_id = projects.first.id
          reply event, "#{nick}, you're on #{user.current_project.name}."
        end
      end,

      %w[story (\d{1,3})].to_regexp =>
      lambda do |nick, event, match|
        begin
          user = User.for_nick nick
          fail NoSearchError unless user.found_stories
          fail IndexError unless story = user.found_stories[match[1].to_i - 1]
          user.current_story_id = story.id
          reply event, "#{nick}'s current story: #{user.current_story.name}"
        rescue NoSearchError
          reply event, "#{nick}, you haven't done a search, and that's too short to be a Pivotal Tracker id."
        rescue IndexError
          reply event, "#{nick}, that story index is too big, your last search only had #{user.found_stories.size} stories in it."
        rescue RestClient::ResourceNotFound
          reply event, "#{nick}, I couldn't find that one. Maybe it's not in your current project (#{user.current_project.name})?"
        end
      end,

      %w[story (\d{4,})].to_regexp =>
      lambda do |nick, event, match|
        begin
          user = User.for_nick nick
          user.current_story_id = match[1]
          reply event, "#{nick}'s current story: #{user.current_story.name}"
        rescue RestClient::ResourceNotFound
          reply event, "#{nick}, I couldn't find that one. Maybe it's not in your current project (#{user.current_project.name})?"
        end
      end,

      %w[story (story_type|estimate|current_state|name) (.+)].to_regexp =>
      lambda do |nick, event, match|
        begin
          user = User.for_nick nick
          fail ChoreFinishedError if user.current_story.story_type == 'chore' and match[1] == 'current_state' and match[2] == 'finished'
          user.update_story match[1] => match[2]
          reply event, "#{user.current_story.id}: #{match[1]} --> #{match[2]}"
        rescue RestClient::ResourceNotFound
          reply event, "#{nick}, I couldn't find that one. Maybe it's not in your current project (#{user.current_project.name})?"
        rescue ChoreFinishedError
          reply event, "#{nick}, chores cannot be 'finished'. You probably want 'accepted'."
        end
      end,

      %w[(?:comment|note) (.+)].to_regexp =>
      lambda do |nick, event, match|
        begin
          user = User.for_nick nick
          user.create_note match[1]
          reply event, "Ok, #{nick}"
        rescue RestClient::ResourceNotFound
          reply event, "#{nick}, I couldn't find that one. Maybe it's not in your current project (#{user.current_project.name})?"
        end
      end,

      %w[find (.+)].to_regexp =>
      lambda do |nick, event, match|
        user = User.for_nick nick
        list_stories user.find_stories(match[1]), event, user
      end,

      %w[finished].to_regexp =>
      lambda do |nick, event, match|
        user = User.for_nick nick
        list_stories user.find_stories(:state => 'finished'), event, user
      end,

      %w[work].to_regexp =>
      lambda do |nick, event, match|
        user = User.for_nick nick

        if user.initials
          list_stories user.find_stories(:owned_by => user.initials, :state => 'started'), event, user
        else
          reply event, "I need your Pivotal Tracker initials please: 'initials <initials>'"
        end
      end,

      %w[work (\w+)].to_regexp =>
      lambda do |nick, event, match|
        user = User.for_nick nick
        user2 = User.for_nick match[1]

        if user2.initials
          list_stories user.find_stories(:owned_by => user2.initials, :state => 'started'), event, user
        else
          reply event, "I need #{match[1]}'s Pivotal Tracker initials please: 'initials #{match[1]} <initials>'"
        end
      end,

      %w[(?:y\w*|list found)].to_regexp =>
      lambda do |nick, event, match|
        user = User.for_nick nick
        list_stories user.found_stories, event, user, true
      end,

      %w[deliver finished].to_regexp =>
      lambda do |nick, event, match|
        user = User.for_nick nick
        stories = user.current_tracker.deliver_all_finished_stories

        if stories.empty?
          reply event, "No finished stories in project :("
        else
          reply event, "Delivered #{stories.size} stories:"
          list_stories stories, event, user
        end
      end,

      %w[projects].to_regexp =>
      lambda do |nick, event, match|
        user = User.for_nick nick

        user.projects.sort_by{|p| p.name}.each_with_index do |project, i|
          reply event, "#{i+1}) #{project.id}: #{project.name}"
        end
      end,

      %w[help].to_regexp =>
      lambda do |nick, event, match|
        reply event, "#{nick}, I'm sending you the command list privately (it's long)..."
        @help.each {|l| reply_privately event, l}
      end
    })
  end

  def list_stories(stories, event, user, force = false)
    too_big = (!force and stories.size > 4 and event.channel.match(/^#/))

    message = "Found #{stories.size} matching #{user.current_project.name} stories."
    message += " Want me to list them in here?" if too_big
    reply event, message

    unless too_big
      stories.each_with_index do |story, i|
        reply event, "#{i+1}) #{story.story_type.capitalize} #{story.id}: #{story.name}"
      end
    end
  end
end

eval <<EOT
class Array
  def to_regexp
    %r|^\#{(['#{options[:nick]},'] + self) * '\\s+'}$|
  end
end
EOT

Trakbot.new(options).start
