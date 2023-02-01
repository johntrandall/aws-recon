# frozen_string_literal: true

#
# Generic wrapper for service clients.
#
# Paging
# ------
# The AWS Ruby SDK has a built-in enumerator in the client response
# object that automatically handles paging large requests. Confirm
# the AWS SDK client call returns a Aws::PageableResponse to take
# advantage of automatic paging.
#
# Retries
# -------
# The AWS Ruby SDK performs retries automatically. We change the
# retry_limit to 9 (10 total requests) and the retry_backoff
# to add 5 seconds delay on each retry for a total max of 55 seconds.
#
class Mapper
  # Services that use us-east-1 endpoint only:
  #   Organizations
  #   Route53Domains
  #   Shield
  #   S3 (unless the bucket was created in another region)
  SINGLE_REGION_SERVICES = %w[route53domains s3 shield support organizations].freeze
  AWS_ARN = ENV["AWS_ARN"]

  def initialize(account, service, region, options)
    @account = account
    @service = service
    @region = region
    @options = options
    @thread = Parallel.worker_number || 0

    # build the client interface
    module_name = "Aws::#{service}::Client"

    # incremental delay on retries (seconds)
    retry_delay = 5

    # default is 3 retries, with 15 second sleep in between
    # reset to 9 retries, with incremental backoff
    client_options = {
      retry_mode: 'legacy', # legacy, standard, or adaptive
      retry_limit: 9, # only legacy
      retry_backoff: ->(context) { sleep(retry_delay * context.retries + 1) }, # only legacy
      http_read_timeout: 10
    }

    # regional service
    client_options.merge!({ region: region }) unless region == 'global'

    # single region services
    client_options.merge!({ region: 'us-east-1' }) if SINGLE_REGION_SERVICES.include?(service.downcase) # rubocop:disable Layout/LineLength

    # debug with wire trace
    client_options.merge!({ http_wire_trace: true }) if @options.debug
    client_options.merge!({credentials: credentials(AWS_ARN, "", client_options[:region])})

    @client = Object.const_get(module_name).new(client_options)
  end

  private

  def _msg(msg)
    base_msg = ["t#{@thread}", @region, @service]
    base_msg.concat(msg)
  end

  def log(*msg)
    return unless @options.verbose

    puts _msg(msg).map(&:to_s).join('.')
  end

  def log_error(*msg)
    return unless @options.verbose

    puts _msg(msg).map(&:to_s).join('.')
  end

  AWS_ACCESS_KEY = ENV['AWS_ACCESS_KEY']
  AWS_SECRET_ACCESS_KEY = ENV['AWS_SECRET_ACCESS_KEY']
  AWS_ROLE_SESSION_NAME = "OL_INFRA_SYNC"


  def credentials(arn, external_id, region)
    Aws::AssumeRoleCredentials.new(
      client: Aws::STS::Client.new(
        region: region,
        credentials: Aws::Credentials.new(AWS_ACCESS_KEY, AWS_SECRET_ACCESS_KEY)
      ),
      role_arn: arn,
      role_session_name: AWS_ROLE_SESSION_NAME
    )
  end
end
