require 'socket'
require 'yaml'
require 'hash_weave' # Hash#weave
# REMOVE DEPENDENCY ON active_support.
require 'rubygems'
require 'active_support'
require 'active_support/core_ext'
require 'active_support/core_ext/hash/indifferent_access'
require 'hash_config'
require 'suffixes'
require 'erb'


##
# See LICENSE.txt for details
#
#=ActiveConfig
#
# * Provides dottable, hash, array, and argument access to YAML 
#   configuration files
# * Implements multilevel caching to reduce disk accesses
# * Overlays multiple configuration files in an intelligent manner
#
# Config file access example:
#  Given a configuration file named test.yaml and test_local.yaml
#  test.yaml:
# ...
# hash_1:
#   foo: "foo"
#   bar: "bar"
#   bok: "bok"
# ...
# test_local.yaml:
# ...
# hash_1:
#   foo: "foo"
#   bar: "baz"
#   zzz: "zzz"
# ...
#
#  irb> ActiveConfig.test
#  => {"array_1"=>["a", "b", "c", "d"], "perform_caching"=>true,
#  "default"=>"yo!", "lazy"=>true, "hash_1"=>{"zzz"=>"zzz", "foo"=>"foo",
#  "bok"=>"bok", "bar"=>"baz"}, "secure_login"=>true, "test_mode"=>true}
#
#  --Notice that the hash produced is the result of merging the above
#  config files in a particular order
#
#  The overlay order of the config files is defined by ActiveConfig._get_file_suffixes:
#  * nil
#  * _local
#  * _config
#  * _local_config
#  * _{environment} (.i.e _development)
#  * _{environment}_local (.i.e _development_local)
#  * _{hostname} (.i.e _whiskey)
#  * _{hostname}_config_local (.i.e _whiskey_config_local)
#
#  ------------------------------------------------------------------
#  irb> ActiveConfig.test_local
#  => {"hash_1"=>{"zzz"=>"zzz", "foo"=>"foo", "bar"=>"baz"}, "test_mode"=>true} 
#

class ActiveConfig
  EMPTY_ARRAY = [ ].freeze unless defined? EMPTY_ARRAY
  def _suffixes
    @suffixes_obj
  end
  def initialize opts={}
    @config_path=opts[:path] || ENV['ACTIVE_CONFIG_PATH']
    @root_file=opts[:root_file] || 'global' 
    @suffixes = opts[:suffixes] if opts[:suffixes]
    @config_refresh = 
      (opts.has_key?(:config_refresh) ? opts[:config_refresh].to_i : 300)
    @suffixes_obj = Suffixes.new
  end
  def _config_path
    @config_path_ary ||=
      begin
        path_sep = (@config_path =~ /;/) ? /;/ : /:/ # Make Wesha happy
        path = @config_path.split(path_sep).reject{ | x | x.empty? }
        path.map!{|x| x.freeze }.freeze
      end
  end
  @@suffixes = { }
  @@cache = {}
  @@cache_files = {}
  @@cache_hash = { }
  @@cache_config_files = { } # Keep around incase reload_disabled.
  @@last_auto_check = { }
  @@on_load = { }
  @@reload_disabled = false
  @@reload_delay = 300
  @@verbose = false

  # DON'T CALL THIS IN production.
  def _flush_cache
    @@suffixes = { }
    @@cache = { } 
    @@cache_files = { } 
    @@cache_hash = { }
    @@last_auto_check = { }
    self
  end

  def _reload_disabled=(x)
    @@reload_disabled = x.nil? ? false : x
  end

  def _reload_delay=(x)
    @@reload_delay = x || 300
  end

  def _verbose=(x)
    @@verbose = x.nil? ? false : x;
  end

  ##
  # Get each config file's yaml hash for the given config name, 
  # to be merged later. Files will only be loaded if they have 
  # not been loaded before or the files have changed within the 
  # last five minutes, or force is explicitly set to true.
  #
  # If file contains the comment:
  #
  #   # ACTIVE_CONFIG:ERB
  #
  # It will be run through ERb before YAML parsing
  # with the following object bound:
  #
  #   active_config.config_file => <<the name of the config.yml file>>
  #   active_config.config_directory => <<the directory of the config.yml>>
  #   active_config.config_name => <<the config name>>
  #   active_config.config_files => <<Array of config files to be parsed>>
  #
  def load_config_files(name, force=false)
    name = name.to_s # if name.is_a?(Symbol)

    # Return last config file hash list loaded,
    # if reload is disabled and files have already been loaded.
    return @@cache_config_files[name] if 
      @@reload_disabled && 
      @@cache_config_files[name]

    now = Time.now

    # Get array of all the existing files file the config name.
    config_files = _get_config_files(name)
    # STDERR.puts "load_config_files(#{name.inspect})"
    
    # Get all the data from all yaml files into as hashes
    hashes = config_files.collect do |f|
      name, name_x, filename, mtime = *f

      # Get the cached file info the specific file, if 
      # it's been loaded before.
      val, last_mtime, last_loaded = @@cache[filename] 

      if @@verbose
        STDERR.puts "f = #{f.inspect}"
        STDERR.puts "cache #{name_x} filename = #{filename.inspect}"
        STDERR.puts "cache #{name_x} val = #{val.inspect}"
        STDERR.puts "cache #{name_x} last_mtime = #{last_mtime.inspect}"
        STDERR.puts "cache #{name_x} last_loaded = #{last_loaded.inspect}"
      end

      # Load the file if its never been loaded or its been more 
      # than 5 minutes since last load attempt.
      if val == nil || 
        now - last_loaded > @@reload_delay
        if force || 
            val == nil || 
            mtime != last_mtime
          
          # mtime is nil if file does not exist.
          if mtime 
            begin
            File.open( filename ) do | yf |
              STDERR.puts "\nActiveConfig: loading #{filename.inspect}" if @@verbose
              # Read raw file data.
              val = yf.read

              # If file has a # ACTIVE_CONFIG:ERB comment,
              # Process it as an ERb first.
              if /^\s*#\s*ACTIVE_CONFIG\s*:\s*ERB/i.match(val)
                # Prepare a object visible from ERb to
                # allow basic substitutions into YAMLs.
                active_config = HashWithIndifferentAccess.new({
                  :config_file => filename,
                  :config_directory => File.dirname(filename),
                  :config_name => name,
                  :config_files => config_files,
                })

                val = ERB.new(val).result(binding)
              end

              # Read file data as YAML.
              val = YAML::load(val)
              # STDERR.puts "ActiveConfig: loaded #{filename.inspect} => #{val.inspect}"
              (@@config_file_loaded ||= { })[name] = config_files
            end
            rescue Exception => err
              raise Exception, "while loading #{filename.inspect}: #{err.inspect}\n  #{err.backtrace.join("  \n")}"
            end
          end
            
          # Save cached config file contents, and mtime.
          @@cache[filename] = [  val, mtime, now ]
          # STDERR.puts "cache[#{filename.inspect}] = #{@@cache[filename].inspect}" if @@verbose && name_x == 'test'

          # Flush merged hash cache.
          @@cache_hash[name] = nil
                 
          # Config files changed or disappeared.
          @@cache_files[name] = config_files

         end
      end

      val
    end
    hashes.compact!

    @@cache_config_files[name] = hashes

    hashes
  end
  def get_config_file(name)
    # STDERR.puts "get_config_file(#{name.inspect})"
    name = name.to_s # if name.is_a?(Symbol)
    now = Time.now
    if (! @@last_auto_check[name]) || (now - @@last_auto_check[name]) > @@reload_delay
      @@last_auto_check[name] = now
      _check_config_changed(name)
    end
    # result = 
    _config_hash(name)
    # STDERR.puts "get_config_file(#{name.inspect}) => #{result.inspect}"; result
  end


  ## 
  # Returns a list of all relavant config files as specified
  # by _get_file_suffixes list.
  # Each element is an Array, containing:
  #   [ "the-top-level-config-name",
  #     "the-suffixed-config-name",
  #     "/the/absolute/path/to/yaml.yml",
  #     # The mtime of the yml file or nil, if it doesn't exist.
  #   ]
  def _get_config_files(name) 
    files = [ ]
    # alexg: splatting *suffix allows us to deal with multipart suffixes 
    # The order these get returned is the order of
    _suffixes.for(name).each do | name_x |
      _config_path.reverse.each do | dir |
        filename = File.join(dir, name_x.to_s + '.yml')
        files <<
        [ name,
          name_x, 
          filename, 
          File.exist?(filename) ? File.stat(filename).mtime : nil, 
        ]
      end
    end

    files
  end

  def _config_files(name)
    @@cache_files[name] ||= _get_config_files(name)
  end

  def config_changed?(name)
    # STDERR.puts "config_changed?(#{name.inspect})"
    name = name.to_s # if name.is_a?(Symbol)
    ! (@@cache_files[name] === _get_config_files(name))
  end

  def _config_hash(name)
    unless result = @@cache_hash[name]
      result = @@cache_hash[name] = 
                     _make_indifferent_and_freeze(
                                        load_config_files(name).inject({ }) { | n, h | n.weave(h, false) })
      STDERR.puts "_config_hash(#{name.inspect}): reloaded" if @@verbose
    end
    result
  end


  ##
  # Register a callback when a config has been reloaded.
  #
  # The config :ANY will register a callback for any config file change.
  #
  # Example:
  #
  #   class MyClass 
  #     @@my_config = { }
  #     ActiveConfig.on_load(:global) do 
  #       @@my_config = { } 
  #     end
  #     def my_config
  #       @@my_config ||= something_expensive_thing_on_config(ACTIVEConfig.global.foobar)
  #     end
  #   end
  #
  def on_load(*args, &blk)
    args << :ANY if args.empty?
    proc = blk.to_proc

    # Call proc on registration.
    proc.call()

    # Register callback proc.
    args.each do | name |
      name = name.to_s
      (@@on_load[name] ||= [ ]) << proc
    end
  end

  # Do reload callbacks.
  def _fire_on_load(name)
    callbacks = 
      (@@on_load['ANY'] || EMPTY_ARRAY) + 
      (@@on_load[name] || EMPTY_ARRAY)
    callbacks.uniq!
    STDERR.puts "_fire_on_load(#{name.inspect}): callbacks = #{callbacks.inspect}" if @@verbose && ! callbacks.empty?
    callbacks.each do | cb |
      cb.call()
    end
  end

  def _check_config_changed(iname=nil)
    iname=iname.nil? ?  @@cache_hash.keys.dup : [*iname]
    ret=iname.map{ | name |
    # STDERR.puts "ActiveConfig: config changed? #{name.inspect} reload_disabled = #{@@reload_disabled}" if @@verbose
    if config_changed?(name) && ! @@reload_disabled 
      STDERR.puts "ActiveConfig: config changed #{name.inspect}" if @@verbose
      if @@cache_hash[name]
        @@cache_hash[name] = nil

        # force on_load triggers.
        _fire_on_load(name)
        name
      end
    end
    }.compact
    return nil if ret.empty?
    ret
  end

  ## 
  # Recursively makes hashes into frozen IndifferentAccess ConfigFakerHash
  # Arrays are also traversed and frozen.
  #
  def _make_indifferent_and_freeze(x)
    case x
    when HashConfig
      unless x.frozen?
        x.each_pair do | k, v |
          x[k] = _make_indifferent_and_freeze(v)
        end
      end
    when Hash
      unless x.frozen?
        x = HashConfig.new.merge!(x)
        x.each_pair do | k, v |
          x[k] = _make_indifferent_and_freeze(v)
        end
      end
      # STDERR.puts "x = #{x.inspect}:#{x.class}"
    when Array
      unless x.frozen?
        x.collect!  do | v |
          _make_indifferent_and_freeze(v)
        end
      end
    end
    x.freeze
  end


  def with_file(name, *args)
    # STDERR.puts "with_file(#{name.inspect}, #{args.inspect})"; result = 
    args.inject(get_config_file(name)) { | v, i | 
      # STDERR.puts "v = #{v.inspect}, i = #{i.inspect}"
      case v
      when Hash
        v[i.to_s]
      when Array
        i.is_a?(Integer) ? v[i] : nil
      else
        nil
      end
    }
    # STDERR.puts "with_file(#{name.inspect}, #{args.inspect}) => #{result.inspect}"; result
  end
 
  #If you are using this in production code, you fail.
  def reload(force = false)
    if force || ! @@reload_disabled
      _flush_cache
    end
    nil
  end

  ## 
  # Disables any reloading of config,
  # executes &block, 
  # calls check_config_changed,
  # returns result of block
  #
  def disable_reload(&block)
    # This should increment @@reload_disabled on entry, decrement on exit.
    # -- kurt@cashnetusa.com 2007/06/12
    result = nil
    reload_disabled_save = @@reload_disabled
    begin
      @@reload_disabled = true
      result = yield
    ensure
      @@reload_disabled = reload_disabled_save
      _check_config_changed unless @@reload_disabled
    end
    result
  end

  ##
  # Gets a value from the global config file
  #
  def [](key, file=_root_file)
    get_config_file(file)[key]
  end

  ##
  # Short-hand access to config file by its name.
  #
  # Example:
  #
  #   ActiveConfig.global(:foo) => ActiveConfig.with_file(:global).foo
  #   ActiveConfig.global.foo   => ActiveConfig.with_file(:global).foo
  #
  def method_missing(method, *args)
    if method.to_s=~/^_(.*)/
      _flush_cache 
      return @suffixes.send($1, *args)
    else 
      value = with_file(method, *args)
      value
    end
  end
end
