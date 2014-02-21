require 'worker_roulette'
require 'benchmark'
require 'eventmachine'

REDIS_CONNECTION_POOL_SIZE = 100
ITERATIONS = 10_000

work_order = {'ding dong' => "hello_foreman_" * 100}
WorkerRoulette.start(size: REDIS_CONNECTION_POOL_SIZE, evented: false)
WorkerRoulette.tradesman_connection_pool.with {|r| r.flushdb}

puts "Redis Connection Pool Size: #{REDIS_CONNECTION_POOL_SIZE}"

Benchmark.bmbm do |x|
  x.report "Time to insert and read #{ITERATIONS} large work_orders" do # ~2500 work_orders / second round trip; 50-50 read-write time; CPU and IO bound
    WorkerRoulette.start(size: REDIS_CONNECTION_POOL_SIZE, evented: false)
    ITERATIONS.times do |iteration|
      sender = 'sender_' + iteration.to_s
      foreman = WorkerRoulette.foreman(sender)
      foreman.enqueue_work_order(work_order)
    end

    ITERATIONS.times do |iteration|
      sender = 'sender_' + iteration.to_s
      tradesman = WorkerRoulette.tradesman
      tradesman.work_orders!
    end
  end
end

EM::Hiredis.reconnect_timeout = 0.01

WorkerRoulette.tradesman_connection_pool.with {|r| r.flushdb}

Benchmark.bmbm do |x|
  x.report "Time for tradesmans to enqueue_work_order and read #{ITERATIONS} large work_orders via pubsub" do # ~2700 work_orders / second round trip
    WorkerRoulette.start(size: REDIS_CONNECTION_POOL_SIZE, evented: false)
    ITERATIONS.times do |iteration|
      p = -> do
        sender = 'sender_' + iteration.to_s
        foreman = WorkerRoulette.foreman(sender)
        foreman.enqueue_work_order(work_order)
      end
      tradesman = WorkerRoulette.tradesman
      tradesman.wait_for_work_orders(p) {|m| m; tradesman.unsubscribe}
    end
  end
end

WorkerRoulette.tradesman_connection_pool.with {|r| r.flushdb}

Benchmark.bmbm do |x|
  x.report "Time to evently insert and read #{ITERATIONS} large work_orders" do # ~4200 work_orders / second round trip; 50-50 read-write time; CPU and IO bound
    EM.run do
      WorkerRoulette.start(evented: true)
      WorkerRoulette.tradesman_connection_pool.with {|r| r.flushdb}
      @total = 0
      @tradesman = WorkerRoulette.a_tradesman

      ITERATIONS.times do |iteration|
        sender = 'sender_' + iteration.to_s
        foreman = WorkerRoulette.a_foreman(sender)
        foreman.enqueue_work_order(work_order) do
          @tradesman.work_orders! do
            @total += 1
            EM.stop if @total == (ITERATIONS - 1)
          end
        end
      end
    end
  end
end

Benchmark.bmbm do |x|
  x.report "Time to evently pubsub insert and read #{ITERATIONS} large work_orders" do # ~5200 work_orders / second round trip; 50-50 read-write time; CPU and IO bound
    EM.run do
      WorkerRoulette.start(evented: true)
      @processed = 0
      @total     = 0
      WorkerRoulette.start(evented: true)
      WorkerRoulette.tradesman_connection_pool.with {|r| r.flushdb}
      @total = 0
      @tradesman = WorkerRoulette.a_tradesman
      on_subscribe = ->(*args) do
        ITERATIONS.times do |iteration|
          sender = 'sender_' + iteration.to_s
          foreman = WorkerRoulette.a_foreman(sender)
          foreman.enqueue_work_order(work_order)
        end
      end
      @tradesman.wait_for_work_orders(on_subscribe) {@processed += 1; EM.stop if @processed == (ITERATIONS - 1)}
    end
  end
end

WorkerRoulette.tradesman_connection_pool.with {|r| r.flushdb}
