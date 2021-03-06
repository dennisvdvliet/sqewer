require 'logger'
require 'thread'
require 'very_tiny_state_machine'
require 'fiber'

# A massively threaded worker engine
class Sqewer::Worker
  DEFAULT_NUM_THREADS = 4
  SLEEP_SECONDS_ON_EMPTY_QUEUE = 1
  THROTTLE_FACTOR = 2

  # @return [Logger] The logger used for job execution
  attr_reader :logger

  # @return [Sqewer::Connection] The connection for sending and receiving messages
  attr_reader :connection

  # @return [Sqewer::Serializer] The serializer for unmarshalling and marshalling
  attr_reader :serializer

  # @return [Sqewer::MiddlewareStack] The stack used when executing the job
  attr_reader :middleware_stack

  # @return [Class] The class to use when instantiating the execution context
  attr_reader :execution_context_class

  # @return [Class] The class used to create the Submitter used by jobs to spawn other jobs
  attr_reader :submitter_class

  # @return [Array<Thread>] all the currently running threads of the Worker
  attr_reader :threads

  # @return [Fixnum] the number of worker threads set up for this Worker
  attr_reader :num_threads

  # Returns a Worker instance, configured based on the default components
  #
  # @return [Sqewer::Worker]
  def self.default
    new
  end

  # Creates a new Worker. The Worker, unlike it is in the Rails tradition, is only responsible for
  # the actual processing of jobs, and not for the job arguments.
  #
  # @param connection[Sqewer::Connection] the object that handles polling and submitting
  # @param serializer[#serialize, #unserialize] the serializer/unserializer for the jobs
  # @param execution_context_class[Class] the class for the execution context (will be instantiated by 
  # the worker for each job execution)
  # @param submitter_class[Class] the class used for submitting jobs (will be instantiated by the worker for each job execution)
  # @param middleware_stack[Sqewer::MiddlewareStack] the middleware stack that is going to be used
  # @param logger[Logger] the logger to log execution to and to pass to the jobs
  # @param num_threads[Fixnum] how many worker threads to spawn
  def initialize(connection: Sqewer::Connection.default,
      serializer: Sqewer::Serializer.default,
      execution_context_class: Sqewer::ExecutionContext,
      submitter_class: Sqewer::Submitter,
      middleware_stack: Sqewer::MiddlewareStack.default,
      logger: Logger.new($stderr),
      num_threads: DEFAULT_NUM_THREADS)

    @logger = logger
    @connection = connection
    @serializer = serializer
    @middleware_stack = middleware_stack
    @execution_context_class = execution_context_class
    @submitter_class = submitter_class
    @num_threads = num_threads

    @threads = []

    raise ArgumentError, "num_threads must be > 0" unless num_threads > 0

    @execution_counter = Sqewer::AtomicCounter.new

    @state = Sqewer::StateLock.new
  end

  # Start listening on the queue, spin up a number of consumer threads that will execute the jobs.
  #
  # @param num_threads[Fixnum] the number of consumer/executor threads to spin up
  # @return [void]
  def start
    @state.transition! :starting

    @logger.info { '[worker] Starting with %d consumer threads' % @num_threads }
    @execution_queue = Queue.new

    consumers = (1..@num_threads).map do
      Thread.new do
        catch(:goodbye) { loop {take_and_execute} }
      end
    end

    # Create the provider thread. When the execution queue is exhausted,
    # grab new messages and place them on the local queue.
    provider = Thread.new do
      loop do
        break if stopping?

        if queue_has_capacity?
          messages = @connection.receive_messages
          if messages.any?
            messages.each {|m| @execution_queue << m }
            @logger.debug { "[worker] Received and buffered %d messages" % messages.length } if messages.any?
          else
            @logger.debug { "[worker] No messages received" }
            Thread.pass
          end
        else
          @logger.debug { "[worker] Cache is full (%d items), postponing receive" % @execution_queue.length }
          sleep SLEEP_SECONDS_ON_EMPTY_QUEUE
        end
      end
    end

    @threads = consumers + [provider]

    # If any of our threads are already dead, it means there is some misconfiguration and startup failed
    if @threads.any?{|t| !t.alive? }
      @threads.map(&:kill)
      @state.transition! :failed
      @logger.fatal { '[worker] Failed to start (one or more threads died on startup)' }
    else
      @state.transition! :running
      @logger.info { '[worker] Started, %d consumer threads' % consumers.length }
    end
  end

  # Attempts to softly stop the running consumers and the producer. Once the call is made,
  # all the threads will stop after the local cache of messages is emptied. This is to ensure that
  # message drops do not happen just because the worker is about to be terminated.
  #
  # The call will _block_ until all the threads of the worker are terminated
  #
  # @return [true]
  def stop
    @state.transition! :stopping
    @logger.info { '[worker] Stopping (clean shutdown), will wait for local cache to drain' }
    loop do
      n_live = @threads.select(&:alive?).length
      break if n_live.zero?

      n_dead = @threads.length - n_live
      @logger.info { '[worker] Staged shutdown, %d threads alive, %d have quit, %d jobs in local cache' %
        [n_live, n_dead, @execution_queue.length] }

      sleep 2
    end

    @threads.map(&:join)
    @logger.info { '[worker] Stopped'}
    @state.transition! :stopped
    true
  end

  # Peforms a hard shutdown by killing all the threads
  def kill
    @state.transition! :stopping
    @logger.info { '[worker] Killing (unclean shutdown), will kill all threads'}
    @threads.map(&:kill)
    @logger.info { '[worker] Stopped'}
    @state.transition! :stopped
  end

  # Prints the status and the backtraces of all controlled threads to the logger
  def debug_thread_information!
    @threads.each do | t |
      @logger.debug { t.inspect }
      @logger.debug { t.backtrace }
    end
  end

  private

  def stopping?
    @state.in_state?(:stopping)
  end

  def queue_has_capacity?
    @execution_queue.length < (@num_threads * THROTTLE_FACTOR)
  end

  def handle_message(message)
    return unless message.receipt_handle

    # Create a messagebox that buffers all the calls to Connection, so that
    # we can send out those commands in one go (without interfering with senders
    # on other threads, as it seems the Aws::SQS::Client is not entirely
    # thread-safe - or at least not it's HTTP client part).
    box = Sqewer::ConnectionMessagebox.new(connection)
    return box.delete_message(message.receipt_handle) unless message.has_body?

    job = middleware_stack.around_deserialization(serializer, message.receipt_handle, message.body) do
      serializer.unserialize(message.body)
    end
    return unless job

    submitter = submitter_class.new(box, serializer)
    context = execution_context_class.new(submitter, {'logger' => logger})

    t = Time.now
    middleware_stack.around_execution(job, context) do
      job.method(:run).arity.zero? ? job.run : job.run(context)
    end
    box.delete_message(message.receipt_handle)

    delta = Time.now - t
    logger.info { "[worker] Finished %s in %0.2fs" % [job.inspect, delta] }
  ensure
    n_flushed = box.flush!
    logger.debug { "[worker] Flushed %d connection commands" % n_flushed } if n_flushed.nonzero?
  end

  def take_and_execute
    message = @execution_queue.pop(nonblock=true)
    handle_message(message)
  rescue ThreadError # Queue is empty
    throw :goodbye if stopping?
    sleep SLEEP_SECONDS_ON_EMPTY_QUEUE
  rescue => e # anything else, at or below StandardError that does not need us to quit
    @logger.error { '[worker] Failed "%s..." with %s: %s' % [message.inspect[0..32], e.class, e.message] }
    e.backtrace.each { |s| @logger.error{"\t#{s}"} }
  end

  def perform(message)
    # Create a messagebox that buffers all the calls to Connection, so that
    # we can send out those commands in one go (without interfering with senders
    # on other threads, as it seems the Aws::SQS::Client is not entirely
    # thread-safe - or at least not it's HTTP client part).
    box = Sqewer::ConnectionMessagebox.new(connection)

    job = middleware_stack.around_deserialization(serializer, message.receipt_handle, message.body) do
      serializer.unserialize(message.body)
    end
    return unless job

    submitter = submitter_class.new(box, serializer)
    context = execution_context_class.new(submitter, {'logger' => logger})

    t = Time.now
    middleware_stack.around_execution(job, context) do
      job.method(:run).arity.zero? ? job.run : job.run(context)
    end

    # Perform two flushes, one for any possible jobs the job has spawned,
    # and one for the job delete afterwards
    box.delete_message(message.receipt_handle)

    delta = Time.now - t
    logger.info { "[worker] Finished %s in %0.2fs" % [job.inspect, delta] }
  ensure
    n_flushed = box.flush!
    logger.debug { "[worker] Flushed %d connection commands" % n_flushed } if n_flushed.nonzero?
  end
end
