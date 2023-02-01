# frozen_string_literal: true

#
# Command line options parser
#
class Parser
  DEFAULT_CONFIG_FILE = nil
  DEFAULT_OUTPUT_FILE = File.expand_path(File.join(Dir.pwd, 'output.json')).freeze
  DEFAULT_S3_PATH = nil
  SERVICES_CONFIG_FILE = File.join(File.dirname(__FILE__), 'services.yaml').freeze
  DEFAULT_FORMAT = 'aws'
  DEFAULT_THREADS = 8
  MAX_THREADS = 128

  Options = Struct.new(
    :regions,
    :services,
    :config_file,
    :s3,
    :output_file,
    :output_format,
    :threads,
    :jsonl,
    :collect_user_data,
    :skip_slow,
    :skip_credential_report,
    :stream_output,
    :verbose,
    :quit_on_exception,
    :debug
  )
  AWS_ACCESS_KEY = ENV['AWS_ACCESS_KEY']
  AWS_SECRET_ACCESS_KEY = ENV['AWS_SECRET_ACCESS_KEY']
  AWS_ROLE_SESSION_NAME = "OL_INFRA_SYNC"

  def self.credentials(arn, external_id, region)
    Aws::AssumeRoleCredentials.new(
      client: Aws::STS::Client.new(
        region: region,
        credentials: Aws::Credentials.new(AWS_ACCESS_KEY, AWS_SECRET_ACCESS_KEY)
      ),
      role_arn: arn,
      role_session_name: AWS_ROLE_SESSION_NAME
    )
  end

  AWS_ARN = ENV["AWS_ARN"]
  def self.parse(options)
    begin
      unless (options & ['-h', '--help']).any?
        creds = credentials(AWS_ARN, "", "us-east-1")
        ec2_client = Aws::EC2::Client.new(region: 'us-east-1', credentials: creds) 
        aws_regions = ec2_client.describe_regions.regions.map(&:region_name)
      end
    rescue Aws::Errors::ServiceError => e
      warn "\nAWS Error: #{e.code}\n\n"
      exit(1)
    end

    aws_services = YAML.load(File.read(SERVICES_CONFIG_FILE), symbolize_names: true)

    args = Options.new(
      aws_regions,
      aws_services.map { |service| service[:name] },
      DEFAULT_CONFIG_FILE,
      DEFAULT_S3_PATH,
      DEFAULT_OUTPUT_FILE,
      DEFAULT_FORMAT,
      DEFAULT_THREADS,
      false,
      false,
      false,
      false,
      false,
      false,
      false,
      false
    )

    opt_parser = OptionParser.new do |opts|
      opts.banner = "\n\x1b[32mAWS Recon\x1b[0m - AWS Inventory Collector (#{AwsRecon::VERSION})\n\nUsage: aws_recon [options]"

      # regions
      opts.on('-r', '--regions [REGIONS]', 'Regions to scan, separated by comma (default: all)') do |regions|
        next if regions.downcase == 'all'

        args.regions = args.regions.filter { |region| regions.split(',').include?(region) }
      end

      # regions to skip
      opts.on('-n', '--not-regions [REGIONS]', 'Regions to skip, separated by comma (default: none)') do |regions|
        next if regions.downcase == 'all'

        args.regions = args.regions.filter { |region| !regions.split(',').include?(region) }
      end

      # services
      opts.on('-s', '--services [SERVICES]', 'Services to scan, separated by comma (default: all)') do |services|
        next if services.downcase == 'all'

        svcs = services.split(',')
        args.services = aws_services.map { |service| service[:name] if svcs.include?(service[:name]) || svcs.include?(service[:alias]) }.compact # rubocop:disable Layout/LineLength
      end

      # services to skip
      opts.on('-x', '--not-services [SERVICES]', 'Services to skip, separated by comma (default: none)') do |services|
        next if services.downcase == 'all'

        svcs = services.split(',')
        args.services = aws_services.map { |service| service[:name] unless svcs.include?(service[:name]) || svcs.include?(service[:alias]) }.compact # rubocop:disable Layout/LineLength
      end

      # config file
      opts.on('-c', '--config [CONFIG]', 'Specify config file for services & regions (e.g. config.yaml)') do |config|
        args.config_file = config
      end

      # write output file to S3 bucket
      opts.on('-b', '--s3-bucket [BUCKET:REGION]', 'Write output file to S3 bucket (default: \'\')') do |bucket_with_region|
        args.stream_output = false
        args.s3 = bucket_with_region
      end

      # output file
      opts.on('-o', '--output [OUTPUT]', 'Specify output file (default: output.json)') do |output|
        args.output_file = File.expand_path(File.join(Dir.pwd, output))
      end

      # output format
      opts.on('-f', '--format [FORMAT]', 'Specify output format (default: aws)') do |f|
        args.output_format = f.downcase if %w[aws custom].include?(f.downcase)
      end

      # threads
      opts.on('-t', '--threads [THREADS]', "Specify max threads (default: #{Parser::DEFAULT_THREADS}, max: 128)") do |threads|
        args.threads = threads.to_i if (0..Parser::MAX_THREADS).include?(threads.to_i)
      end

      # output NDJSON/JSONL format
      opts.on('-l', '--json-lines', 'Output NDJSON/JSONL format (default: false)') do
        args.jsonl = true
      end

      # collect EC2 instance user data
      opts.on('-u', '--user-data', 'Collect EC2 instance user data (default: false)') do
        args.collect_user_data = true
      end

      # skip slow operations
      opts.on('-z', '--skip-slow', 'Skip slow operations (default: false)') do
        args.skip_slow = true
      end

      # skip generating IAM credential report
      opts.on('-g', '--skip-credential-report', 'Skip generating IAM credential report (default: false)') do
        args.skip_credential_report = true
      end

      # stream output (forces JSON lines, doesn't output handled warnings or errors )
      opts.on('-j', '--stream-output', 'Stream JSON lines to stdout (default: false)') do
        args.output_file = nil
        args.verbose = false
        args.debug = false
        args.stream_output = true
      end

      # verbose
      opts.on('-v', '--verbose', 'Output client progress and current operation') do
        args.verbose = true unless args.stream_output
      end

      # re-raise exceptions
      opts.on('-q', '--quit-on-exception', 'Stop collection if an API error is encountered (default: false)') do
        args.quit_on_exception = true
      end

      # debug
      opts.on('-d', '--debug', 'Output debug with wire trace info') do
        unless args.stream_output
          args.debug = true
          args.verbose = true
        end
      end

      opts.on('-h', '--help', 'Print this help information') do
        puts opts
        exit
      end
    end

    opt_parser.parse!(options)
    args
  end
end
