# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'rubygems/package'
require 'uri'

class BundlerSourceAwsS3 < Bundler::Plugin::API
  class S3AccessError < Bundler::BundlerError
    attr_reader :uri, :aws_error

    def initialize(uri, aws_error)
      @uri = uri
      @aws_error = aws_error
    end

    def message
      "[aws-s3] Error: There was an error while trying to access S3 bucket `#{uri}`.\n" \
      "Make sure you have correct S3 access via running aws cli locally.\n" \
      " > Internal Error: #{aws_error}\n" \
      "If you're using sso login, please run: aws sso login"
    end

    def status_code
      40
    end
  end

  class S3Source < Bundler::Source
    # Bundler plugin api, we need to install the gem for the given spec and
    # then call post_install.
    def install(spec, _opts)
      print_using_message "Using #{spec.name} #{spec.version} from #{self}"

      validate!(spec)

      package = package_for(spec)
      destination = install_path.join(spec.full_name)

      Bundler.mkdir_p(destination)
      package.extract_files(destination)
      File.open(spec.loaded_from, 'wb') { |f| f.write spec.to_ruby }

      post_install(spec)
    end

    # Bundler plugin api, we need to return a Bundler::Index
    def specs
      @specs ||= begin
        # remote_specs usually generates a way larger Index than the other
        # sources, and large_idx.use small_idx is way faster than
        # small_idx.use large_idx.
        idx = @allow_remote ? remote_specs.dup : Bundler::Index.new
        idx.use(cached_specs, :override_dupes) if @allow_cached || @allow_remote
        idx.use(installed_specs, :override_dupes)
        idx
      end
    end

    def app_cache_dirname
      base_name = File.basename(Bundler::URI.parse(uri).normalize.host)
      "s3-#{base_name}"
    end

    # Bundler calls this to tell us fetching remote gems is okay.
    def remote!
      @specs = nil
      @allow_remote = true
    end

    def cache(spec, custom_path = nil)
      new_cache_path = app_cache_path(custom_path)
      gem_filename = "#{spec.full_name}.gem"
      FileUtils.mkdir_p(new_cache_path)
      FileUtils.touch(app_cache_path.join('.bundlecache'))
      FileUtils.cp(s3_gems_path.join('gems').join(gem_filename), new_cache_path.join(gem_filename))
    end

    def unlock!
      FileUtils.rm_rf(install_path)
      @specs = nil
    end

    def cached!
      @specs = nil
      @allow_cached = true
    end

    def to_s
      "aws-s3 plugin with uri #{uri}"
    end

    private

    def fetch_bundler_object(path)
      full_path = URI.join(uri, path).to_s
      Tempfile.create("aws-s3-#{bucket}-specs") do |file|
        system("aws s3 cp #{full_path} #{file.path}")
        file.path
          .yield_self { |p| Gem.read_binary(p) }
          .yield_self { |bin| path.match?(/\.gz|\.rz$/) ? Bundler.rubygems.inflate(bin) : bin }
          .yield_self { |marshal_data| Bundler.load_marshal marshal_data }
      end
    end

    def remote_specs
      @remote_specs ||=
        Bundler::Index.build do |index|
          index.use fetch_bundler_object("specs.#{Gem.marshal_version}.gz")
        end
    end

    def installed_specs
      @installed_specs ||= Bundler::Index.build do |idx|
        Dir["#{install_path}/*.gem"].each do |gemfile|
          spec = Bundler.rubygems.spec_from_gem(gemfile)
          spec.source = self
          spec.loaded_from = loaded_from_for(spec)

          idx << spec
        end
      end
    end

    def cached_specs
      @cached_specs ||= begin
        idx = installed_specs.dup

        Dir["#{app_cache_path}/*.gem"].each do |gemfile|
          spec = Bundler.rubygems.spec_from_gem(gemfile)
          spec.source = self

          spec.loaded_from = loaded_from_for(spec)
          idx << spec
        end

        idx
      end
    end

    # This is a guard against attempting to install a spec that doesn't match
    # our requirements / expectations.
    #
    # If we want to be more trusting, we could probably safely remove this
    # method.
    def validate!(spec)
      return if spec.source == self && spec.loaded_from == loaded_from_for(spec)

      raise "[aws-s3] Error #{spec.full_name} spec is not valid"
    end

    # We will use this value as the given spec's loaded_from. It should be the
    # path of the installed gem's gemspec.
    def loaded_from_for(spec)
      destination = install_path.join(spec.full_name)
      destination.join("#{spec.full_name}.gemspec").to_s
    end

    # This path is going to be under bundler's gem_install_dir and we'll then
    # mirror the bucket/path directory structure from the source. This is where
    # we want to place our gems. This directory can hold multiple installed
    # gems.
    def install_path
      @install_path ||= Bundler.home.join('s3-gems').join(bucket).join(path)
    end

    # This is the path to the s3 gems for our source uri. We will pull the s3
    # gems into this directory.
    def s3_gems_path
      Bundler
        .user_bundle_path
        .join('bundler-source-aws-s3').join(bucket).join(path)
    end

    # Pull s3 gems from the source and store them in
    # .bundle/bundler-source-aws-s3/<bucket>/<path>. We will install, etc, from
    # this directory.
    def pull
      # We only want to pull once in a single bundler run.
      return @pull if defined?(@pull)

      Bundler.mkdir_p(s3_gems_path)

      @pull = sync_gems
    end

    def sync_gems
      log, res = Open3.capture2e(sync_cmd)
      return true if res.success?

      if system('grep -q "sso_start_url" ~/.aws/config')
        Bundler.ui.info "`#{sync_cmd}` failed. Trying `aws sso login`..."
        system('aws sso login')
        log, res = Open3.capture2e(sync_cmd)
        return if res.success?
      end

      raise S3AccessError.new(uri, "#{sync_cmd.inspect} failed. #{log}")
    end

    # Produces a list of Gem::Package for the s3 gems.
    def packages
      @packages ||= Dir[s3_gems_path.join('gems')]
        .map { |entry| s3_gems_path.join('gems').join(entry) }
        .select { |gem_path| File.file?(gem_path) }
        .map { |gem_path| Gem::Package.new(gem_path.to_s) }
    end

    # Find the Gem::Package for a given spec.
    def package_for(spec)
      packages.find { |package| package.spec.full_name == spec.full_name }
    end

    def sync_cmd
      "aws s3 sync --delete #{uri} #{s3_gems_path}"
    end

    def bucket
      URI.parse(uri).normalize.host
    end

    def path
      # Remove the leading slash from the path.
      URI.parse(uri).normalize.path[1..-1]
    end
  end

  source 'aws-s3', S3Source
end
