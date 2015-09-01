module ScoutApm
  module ServerIntegrations
    class Puma
      attr_reader :logger

      def initialize(logger)
        @logger = logger
      end

      def name
        :puma
      end

      def forking?
        return false unless defined?(::Puma)
        options = ::Puma.cli_config.instance_variable_get(:@options)
        logger.debug options.inspect
        options[:preload_app]
      rescue
        false
      end

      def present?
        defined?(::Puma) && (File.basename($0) =~ /\Apuma/)
      end

      def install
        ::Puma.cli_config.options[:before_worker_boot] << Proc.new do
          logger.debug "Installing Puma worker loop."
          ScoutApm::Agent.instance.start_background_worker
        end
      rescue
        logger.warn "Unable to install Puma worker loop: #{$!.message}"
      end

      def found?
        true
      end
    end
  end
end
