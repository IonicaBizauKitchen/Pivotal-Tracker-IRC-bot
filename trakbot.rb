require 'optparse'
require 'chatbot'
require 'rubygems'
gem 'jsmestad-pivotal-tracker'
require 'pivotal-tracker'
require 'pp'
require 'yaml'


options = {
  :channel => 'traktest',
  :full => 'Pivotal Tracker IRC bot',
  :nick => 'trakbot',
  :port => '6667',
  :server => 'irc.freenode.net',
  :logging => :warn,
  :storage_file => 'state.yml'
}

optparse = OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options]"

  opts.on('-u', '--username USERNAME', 'Specify rifftrax.com username.') {|options[:username]|}
  opts.on('-w', '--password PASSWORD', 'Specify rifftrax.com password.') {|options[:password]|}
  opts.on('-c', '--channel NAME', 'Specify IRC channel to /join. (test)') {|options[:channel]|}
  opts.on('-f', '--full-name NICK', 'Specify the bot\'s IRC full name. (iRiff report bot)') {|options[:full]|}
  opts.on('-n', '--nick NICK', 'Specify the bot\'s IRC nick. (riffbot)') {|options[:nick]|}
  opts.on('-s', '--server HOST', 'Specify IRC server hostname. (irc.freenode.net)') {|options[:server]|}
  opts.on('-p', '--port NUMBER', Integer, 'Specify IRC port number. (6667)') {|options[:port]|}
  opts.on('-l', '--logging LEVEL', [:debug, :info, :warn, :error, :fatal], 'Logging level (debug, info, warn, error, fatal) (warn)') {|options[:logging]|}
  opts.on('-y', '--storage-file FILENAME', 'The file trakbot will use to store its state. (storage.yml)') {|options[:storage_file]|}

  #opts.on('-i', '--interval MINUTES', Integer, 'Number of minutes to sleep between checks (10)') do |interval|
    #fail "Interval minimum is 5 minutes." unless interval >= 5
    #options[:interval] = interval
  #end

  opts.on_tail('-h', '--help', 'Display this screen') {puts opts; exit}
end

optparse.parse!

class Hash
  # from http://snippets.dzone.com/user/dubek
  # Replacing the to_yaml function so it'll serialize hashes sorted (by their keys)
  #
  # Original function is in /usr/lib/ruby/1.8/yaml/rubytypes.rb
  def to_yaml( opts = {} )
    YAML::quick_emit( object_id, opts ) do |out|
      out.map( taguri, to_yaml_style ) do |map|
        sort.each do |k, v|   # <-- here's my addition (the 'sort')
          map.add( k, v )
        end
      end
    end
  end
end

class Symbol
  def <=>(a)
    self.to_s <=> a.to_s
  end
end

class Trakbot < Chatbot
  def initialize(options)
    super options[:nick], options[:server], options[:port], options[:full]
    @options = options

	@help =<<EOT
#{options[:nick]} help: this
#{options[:nick]} token <token>: Teach trakbot your nick's Pivotal Tracker API token
#{options[:nick]} new project <id>: Add a project to trakbot via its id
#{options[:nick]} project <id>: Set your current project
#{options[:nick]} projects: List known projects
#{options[:nick]} finished: List finished stories in project
#{options[:nick]} deliver finished: Deliver (and display) all finished stories
#{options[:nick]} new (feature|chore|bug|release) <name>: Create a story in the Icebox with given name
EOT

    @logger.level = eval "Logger::#{options[:logging].to_s.upcase}"

    load_state
    @tracker = {}

    # The channel to join.
    add_room('#' + options[:channel])

    # Here you can modify the trigger phrase
    add_actions({
      /^#{@options[:nick]}\s+token\s*(\S+)$/ => lambda {|e,m|
        ensure_user e.from
        @state[:users][e.from][:token] = m[1]
        save_state
        reply e, "Got it, #{e.from}."
      },

      /^#{@options[:nick]}\s+new\s+(feature|chore|bug|release)\s+(.+)$/ => lambda {|e,m|
        t = ensure_tracker e.from, @state[:users][e.from][:current_project]
	story = t.create_story Story.new(:name => m[2], :story_type => m[1])
        reply e, "Added story #{story.id}"
      },

      /^#{@options[:nick]}\s+new\s+project\s+(\S+)$/ => lambda {|e,m|
        @state[:users][e.from][:projects][m[1]] ||= {}
        t = ensure_tracker e.from, m[1]
        save_state
        reply e, "Added project: #{t.project.name}"
      },

      /^#{@options[:nick]}\s+project\s+(\S+)$/ => lambda {|e,m|
        @state[:users][e.from][:projects][m[1]] ||= {}
        t = ensure_tracker e.from, m[1]
	@state[:users][e.from][:current_project] = m[1]
        save_state
        reply e, "#{e.from}'s current project: #{t.project.name}"
      },

      /^#{@options[:nick]}\s+finished/ => lambda {|e,m|
        t = ensure_tracker e.from, @state[:users][e.from][:current_project]
	t.find(:state => 'finished').each do |s|
	  reply e, "#{s.story_type.capitalize} #{s.id}: #{s.name}"
	end
      },

      /^#{@options[:nick]}\s+deliver\s+finished/ => lambda {|e,m|
        t = ensure_tracker e.from, @state[:users][e.from][:current_project]
	stories = t.deliver_all_finished_stories
	if stories.empty?
	  reply e, "No finished stories in project :("
	else
	  reply e, "Delivered #{stories.size} stories:"
	  stories.each {|s| reply e, "#{s.story_type.capitalize} #{s.id}: #{s.name}"}
	end
      },

      /^#{@options[:nick]}\s+projects/ => lambda {|e,m|
          @state[:users][e.from][:projects].keys.each {|p| reply e, "#{p}: " + ensure_tracker(e.from, p).project.name}
      },

      /^(#{@options[:nick]}.*help|\.\?)$/ => lambda {|e,m| @help.each_line{|l| reply e, l}}
    })
  end

  def ensure_user(nick)
    @state[:users][nick] ||= {:projects => {}}
  end

  def ensure_tracker(nick, project_id)
    @tracker["#{nick}.#{project_id}"] ||= PivotalTracker.new project_id, @state[:users][nick][:token]
  end

  def save_state
    @logger.debug "Saving state: #{@state.pretty_inspect.chomp}"
    File.open(@options[:storage_file], 'w') {|f| f.print @state.to_yaml}
  end

  def load_state
    if File.exists? @options[:storage_file]
      @logger.info "Loading state from #{@options[:storage_file]}"
      @state = YAML::load File.read(@options[:storage_file])
      @logger.debug "Loaded state: #{@state.pretty_inspect}"
    else
      @logger.warn "Storage file not found, starting a new one at #{@options[:storage_file]}"
      @state = {
        :users => {}
      }
      save_state
    end
  end
end

Trakbot.new(options).start
