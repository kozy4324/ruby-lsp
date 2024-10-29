# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "bundler"
require "fileutils"
require "pathname"
require "digest"
require "time"
require "uri"

# This file is a script that will configure a custom bundle for the Ruby LSP. The custom bundle allows developers to use
# the Ruby LSP without including the gem in their application's Gemfile while at the same time giving us access to the
# exact locked versions of dependencies.

Bundler.ui.level = :silent

module RubyLsp
  class SetupBundler
    extend T::Sig

    class BundleNotLocked < StandardError; end
    class BundleInstallFailure < StandardError; end

    FOUR_HOURS = T.let(4 * 60 * 60, Integer)

    sig { params(project_path: String, options: T.untyped).void }
    def initialize(project_path, **options)
      @project_path = project_path
      @branch = T.let(options[:branch], T.nilable(String))
      @launcher = T.let(options[:launcher], T.nilable(T::Boolean))

      # Regular bundle paths
      @gemfile = T.let(
        begin
          Bundler.default_gemfile
        rescue Bundler::GemfileNotFound
          nil
        end,
        T.nilable(Pathname),
      )
      @lockfile = T.let(@gemfile ? Bundler.default_lockfile : nil, T.nilable(Pathname))

      @gemfile_name = T.let(@gemfile&.basename&.to_s || "Gemfile", String)

      # Custom bundle paths
      @custom_dir = T.let(Pathname.new(".ruby-lsp").expand_path(@project_path), Pathname)
      @custom_gemfile = T.let(@custom_dir + @gemfile_name, Pathname)
      @custom_lockfile = T.let(@custom_dir + (@lockfile&.basename || "Gemfile.lock"), Pathname)
      @lockfile_hash_path = T.let(@custom_dir + "main_lockfile_hash", Pathname)
      @last_updated_path = T.let(@custom_dir + "last_updated", Pathname)

      dependencies, bundler_version = load_dependencies
      @dependencies = T.let(dependencies, T::Hash[String, T.untyped])
      @bundler_version = T.let(bundler_version, T.nilable(Gem::Version))
      @rails_app = T.let(rails_app?, T::Boolean)
      @retry = T.let(false, T::Boolean)
    end

    # Sets up the custom bundle and returns the `BUNDLE_GEMFILE`, `BUNDLE_PATH` and `BUNDLE_APP_CONFIG` that should be
    # used for running the server
    sig { returns(T::Hash[String, String]) }
    def setup!
      raise BundleNotLocked if !@launcher && @gemfile&.exist? && !@lockfile&.exist?

      # Automatically create and ignore the .ruby-lsp folder for users
      @custom_dir.mkpath unless @custom_dir.exist?
      ignore_file = @custom_dir + ".gitignore"
      ignore_file.write("*") unless ignore_file.exist?

      # Do not set up a custom bundle if LSP dependencies are already in the Gemfile
      if @dependencies["ruby-lsp"] &&
          @dependencies["debug"] &&
          (@rails_app ? @dependencies["ruby-lsp-rails"] : true)
        $stderr.puts(
          "Ruby LSP> Skipping custom bundle setup since LSP dependencies are already in #{@gemfile}",
        )

        return run_bundle_install
      end

      write_custom_gemfile

      unless @gemfile&.exist? && @lockfile&.exist?
        $stderr.puts("Ruby LSP> Skipping lockfile copies because there's no top level bundle")
        return run_bundle_install(@custom_gemfile)
      end

      lockfile_contents = @lockfile.read
      current_lockfile_hash = Digest::SHA256.hexdigest(lockfile_contents)

      if @custom_lockfile.exist? && @lockfile_hash_path.exist? && @lockfile_hash_path.read == current_lockfile_hash
        $stderr.puts(
          "Ruby LSP> Skipping custom bundle setup since #{@custom_lockfile} already exists and is up to date",
        )
        return run_bundle_install(@custom_gemfile)
      end

      FileUtils.cp(@lockfile.to_s, @custom_lockfile.to_s)
      correct_relative_remote_paths
      @lockfile_hash_path.write(current_lockfile_hash)
      run_bundle_install(@custom_gemfile)
    end

    private

    sig { returns(T::Hash[String, T.untyped]) }
    def custom_bundle_dependencies
      @custom_bundle_dependencies ||= T.let(
        begin
          if @custom_lockfile.exist?
            ENV["BUNDLE_GEMFILE"] = @custom_gemfile.to_s
            Bundler::LockfileParser.new(@custom_lockfile.read).dependencies
          else
            {}
          end
        end,
        T.nilable(T::Hash[String, T.untyped]),
      )
    ensure
      ENV.delete("BUNDLE_GEMFILE")
    end

    sig { void }
    def write_custom_gemfile
      parts = [
        "# This custom gemfile is automatically generated by the Ruby LSP.",
        "# It should be automatically git ignored, but in any case: do not commit it to your repository.",
        "",
      ]

      # If there's a top level Gemfile, we want to evaluate from the custom bundle. We get the source from the top level
      # Gemfile, so if there isn't one we need to add a default source
      if @gemfile&.exist? && @lockfile&.exist?
        parts << "eval_gemfile(File.expand_path(\"../#{@gemfile_name}\", __dir__))"
      else
        parts.unshift('source "https://rubygems.org"')
      end

      unless @dependencies["ruby-lsp"]
        ruby_lsp_entry = +'gem "ruby-lsp", require: false, group: :development'
        ruby_lsp_entry << ", github: \"Shopify/ruby-lsp\", branch: \"#{@branch}\"" if @branch
        parts << ruby_lsp_entry
      end

      unless @dependencies["debug"]
        parts << 'gem "debug", require: false, group: :development, platforms: :mri'
      end

      if @rails_app && !@dependencies["ruby-lsp-rails"]
        parts << 'gem "ruby-lsp-rails", require: false, group: :development'
      end

      content = parts.join("\n")
      @custom_gemfile.write(content) unless @custom_gemfile.exist? && @custom_gemfile.read == content
    end

    sig { returns([T::Hash[String, T.untyped], T.nilable(Gem::Version)]) }
    def load_dependencies
      return [{}, nil] unless @lockfile&.exist?

      # We need to parse the Gemfile.lock manually here. If we try to do `bundler/setup` to use something more
      # convenient, we may end up with issues when the globally installed `ruby-lsp` version mismatches the one included
      # in the `Gemfile`
      lockfile_parser = Bundler::LockfileParser.new(@lockfile.read)
      dependencies = lockfile_parser.dependencies

      # When working on a gem, the `ruby-lsp` might be listed as a dependency in the gemspec. We need to make sure we
      # check those as well or else we may get version mismatch errors. Notice that bundler allows more than one
      # gemspec, so we need to make sure we go through all of them
      Dir.glob("{,*}.gemspec").each do |path|
        dependencies.merge!(Bundler.load_gemspec(path).dependencies.to_h { |dep| [dep.name, dep] })
      end

      [dependencies, lockfile_parser.bundler_version]
    end

    sig { params(bundle_gemfile: T.nilable(Pathname)).returns(T::Hash[String, String]) }
    def run_bundle_install(bundle_gemfile = @gemfile)
      env = bundler_settings_as_env
      env["BUNDLE_GEMFILE"] = bundle_gemfile.to_s

      # If the user has a custom bundle path configured, we need to ensure that we will use the absolute and not
      # relative version of it when running `bundle install`. This is necessary to avoid installing the gems under the
      # `.ruby-lsp` folder, which is not the user's intention. For example, if the path is configured as `vendor`, we
      # want to install it in the top level `vendor` and not `.ruby-lsp/vendor`
      if env["BUNDLE_PATH"]
        env["BUNDLE_PATH"] = File.expand_path(env["BUNDLE_PATH"], @project_path)
      end

      base_bundle = base_bundle_command(env)

      # If `ruby-lsp` and `debug` (and potentially `ruby-lsp-rails`) are already in the Gemfile, then we shouldn't try
      # to upgrade them or else we'll produce undesired source control changes. If the custom bundle was just created
      # and any of `ruby-lsp`, `ruby-lsp-rails` or `debug` weren't a part of the Gemfile, then we need to run `bundle
      # install` for the first time to generate the Gemfile.lock with them included or else Bundler will complain that
      # they're missing. We can only update if the custom `.ruby-lsp/Gemfile.lock` already exists and includes all gems

      # When not updating, we run `(bundle check || bundle install)`
      # When updating, we run `((bundle check && bundle update ruby-lsp debug) || bundle install)`
      command = +"(#{base_bundle} check"

      if should_bundle_update?
        # If any of `ruby-lsp`, `ruby-lsp-rails` or `debug` are not in the Gemfile, try to update them to the latest
        # version
        command.prepend("(")
        command << " && #{base_bundle} update "
        command << "ruby-lsp " unless @dependencies["ruby-lsp"]
        command << "debug " unless @dependencies["debug"]
        command << "ruby-lsp-rails " if @rails_app && !@dependencies["ruby-lsp-rails"]
        command.delete_suffix!(" ")
        command << ")"

        @last_updated_path.write(Time.now.iso8601)
      end

      command << " || #{base_bundle} install) "

      # Redirect stdout to stderr to prevent going into an infinite loop. The extension might confuse stdout output with
      # responses
      command << "1>&2"

      # Add bundle update
      $stderr.puts("Ruby LSP> Running bundle install for the custom bundle. This may take a while...")
      $stderr.puts("Ruby LSP> Command: #{command}")

      # Try to run the bundle install or update command. If that fails, it normally means that the custom lockfile is in
      # a bad state that no longer reflects the top level one. In that case, we can remove the whole directory, try
      # another time and give up if it fails again
      if !system(env, command) && !@retry && @custom_gemfile.exist?
        @retry = true
        @custom_dir.rmtree
        $stderr.puts("Ruby LSP> Running bundle install failed. Trying to re-generate the custom bundle from scratch")
        return setup!
      end

      env
    end

    # Gather all Bundler settings (global and local) and return them as a hash that can be used as the environment
    sig { returns(T::Hash[String, String]) }
    def bundler_settings_as_env
      local_config_path = File.join(@project_path, ".bundle")

      # If there's no Gemfile or if the local config path does not exist, we return an empty setting set (which has the
      # global settings included). Otherwise, we also load the local settings
      settings = begin
        Dir.exist?(local_config_path) ? Bundler::Settings.new(local_config_path) : Bundler::Settings.new
      rescue Bundler::GemfileNotFound
        Bundler::Settings.new
      end

      # Map all settings to their environment variable names with `key_for` and their values. For example, the if the
      # setting name `e` is `path` with a value of `vendor/bundle`, then it will return `"BUNDLE_PATH" =>
      # "vendor/bundle"`
      settings.all.to_h do |e|
        key = Bundler::Settings.key_for(e)
        value = Array(settings[e]).join(":").tr(" ", ":")

        [key, value]
      end
    end

    sig { void }
    def install_bundler_if_needed
      # Try to find the bundler version specified in the lockfile in installed gems. If not found, install it
      requirement = Gem::Requirement.new(@bundler_version.to_s)
      return if Gem::Specification.any? { |s| s.name == "bundler" && requirement =~ s.version }

      Gem.install("bundler", @bundler_version.to_s)
    end

    sig { returns(T::Boolean) }
    def should_bundle_update?
      # If `ruby-lsp`, `ruby-lsp-rails` and `debug` are in the Gemfile, then we shouldn't try to upgrade them or else it
      # will produce version control changes
      if @rails_app
        return false if @dependencies.values_at("ruby-lsp", "ruby-lsp-rails", "debug").all?

        # If the custom lockfile doesn't include `ruby-lsp`, `ruby-lsp-rails` or `debug`, we need to run bundle install
        # before updating
        return false if custom_bundle_dependencies.values_at("ruby-lsp", "debug", "ruby-lsp-rails").any?(&:nil?)
      else
        return false if @dependencies.values_at("ruby-lsp", "debug").all?

        # If the custom lockfile doesn't include `ruby-lsp` or `debug`, we need to run bundle install before updating
        return false if custom_bundle_dependencies.values_at("ruby-lsp", "debug").any?(&:nil?)
      end

      # If the last updated file doesn't exist or was updated more than 4 hours ago, we should update
      !@last_updated_path.exist? || Time.parse(@last_updated_path.read) < (Time.now - FOUR_HOURS)
    end

    # When a lockfile has remote references based on relative file paths, we need to ensure that they are pointing to
    # the correct place since after copying the relative path is no longer valid
    sig { void }
    def correct_relative_remote_paths
      content = @custom_lockfile.read
      content.gsub!(/remote: (.*)/) do |match|
        path = T.must(Regexp.last_match)[1]

        # We should only apply the correction if the remote is a relative path. It might also be a URI, like
        # `https://rubygems.org` or an absolute path, in which case we shouldn't do anything
        if path && !URI(path).scheme
          "remote: #{File.expand_path(path, T.must(@gemfile).dirname)}"
        else
          match
        end
      end

      @custom_lockfile.write(content)
    end

    # Detects if the project is a Rails app by looking if the superclass of the main class is `Rails::Application`
    sig { returns(T::Boolean) }
    def rails_app?
      config = Pathname.new("config/application.rb").expand_path
      application_contents = config.read(external_encoding: Encoding::UTF_8) if config.exist?
      return false unless application_contents

      /class .* < (::)?Rails::Application/.match?(application_contents)
    end

    # Returns the base bundle command we should use for this project, which will be:
    # - `bundle` if there's no locked Bundler version and no `bin/bundle` binstub in the $PATH
    # - `bundle _<version>_` if there's a locked Bundler version
    # - `bin/bundle` if there's a `bin/bundle` binstub in the $PATH
    sig { params(env: T::Hash[String, String]).returns(String) }
    def base_bundle_command(env)
      path_parts = if Gem.win_platform?
        ENV["Path"] || ENV["PATH"] || ENV["path"] || ""
      else
        ENV["PATH"] || ""
      end.split(File::PATH_SEPARATOR)

      bin_dir = File.expand_path("bin", @project_path)
      bundle_binstub = File.join(@project_path, "bin", "bundle")

      if File.exist?(bundle_binstub) && path_parts.any? { |path| File.expand_path(path, @project_path) == bin_dir }
        return bundle_binstub
      end

      if @bundler_version
        env["BUNDLER_VERSION"] = @bundler_version.to_s
        install_bundler_if_needed
        return "bundle _#{@bundler_version}_"
      end

      "bundle"
    end
  end
end
