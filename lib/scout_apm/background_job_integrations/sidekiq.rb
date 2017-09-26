module ScoutApm
  module BackgroundJobIntegrations
    class Sidekiq
      attr_reader :logger

      def name
        :sidekiq
      end

      def present?
        defined?(::Sidekiq) && File.basename($PROGRAM_NAME).start_with?('sidekiq')
      end

      def forking?
        false
      end

      def install
        install_tracer
        add_middleware
        install_processor
      end

      def install_tracer
        # ScoutApm::Tracer is not available when this class is defined
        SidekiqMiddleware.class_eval do
          include ScoutApm::Tracer
        end
      end

      def add_middleware
        ::Sidekiq.configure_server do |config|
          config.server_middleware do |chain|
            chain.add SidekiqMiddleware
          end
        end
      end

      def install_processor
        require 'sidekiq/processor' # sidekiq v4 has not loaded this file by this point

        ::Sidekiq::Processor.class_eval do
          def initialize_with_scout(boss)
            agent = ::ScoutApm::Agent.instance
            agent.start_background_worker
            initialize_without_scout(boss)
          end

          alias_method :initialize_without_scout, :initialize
          alias_method :initialize, :initialize_with_scout
        end
      end
    end

    # We insert this middleware into the Sidekiq stack, to capture each job,
    # and time them.
    class SidekiqMiddleware
      def call(_worker, msg, queue)
        req = ScoutApm::RequestManager.lookup
        req.job!
        req.annotate_request(:queue_latency => latency(msg))

        queue_layer = ScoutApm::Layer.new('Queue', queue)
        job_layer = ScoutApm::Layer.new('Job', job_class(msg))

        if ScoutApm::Agent.instance.config.value('profile') && SidekiqMiddleware.version_supports_profiling?
          # Capture ScoutProf if we can
          #req.enable_profiled_thread!
          #job_layer.set_root_class(job_class)
          #job_layer.traced!
        end

        begin
          req.start_layer(queue_layer)
          started_queue = true
          req.start_layer(job_layer)
          started_job = true

          yield
        rescue
          req.error!
          raise
        ensure
          req.stop_layer if started_job
          req.stop_layer if started_queue
        end
      end

      UNKNOWN_CLASS_PLACEHOLDER = 'UnknownJob'.freeze
      ACTIVE_JOB_KLASS = 'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper'.freeze
      DELAYED_WRAPPER_KLASS = 'Sidekiq::Extensions::DelayedClass'.freeze


      def job_class(msg)
        job_class = msg.fetch('class', UNKNOWN_CLASS_PLACEHOLDER)

        if job_class == ACTIVE_JOB_KLASS && msg.key?('wrapped')
          begin
            job_class = msg['wrapped']
          rescue
            ACTIVE_JOB_KLASS
          end
        elsif job_class == DELAYED_WRAPPER_KLASS
          begin
            yml = msg['args'].first
            deserialized_args = YAML.load(yml)
            klass, method, *rest = deserialized_args
            job_class = [klass,method].map(&:to_s).join(".")
          rescue
            DELAYED_WRAPPER_KLASS
          end
        end

        job_class
      rescue
        UNKNOWN_CLASS_PLACEHOLDER
      end

      def latency(msg, time = Time.now.to_f)
        created_at = msg['enqueued_at'] || msg['created_at']
        if created_at
          (time - created_at)
        else
          0
        end
      rescue
        0
      end

      def self.version_supports_profiling?
        @@sidekiq_supports_profling ||= defined?(::Sidekiq::VERSION) && Gem::Dependency.new('', '~> 4.0').match?('', ::Sidekiq::VERSION.to_s)
      end
    end # SidekiqMiddleware
  end
end
