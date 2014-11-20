require 'worker_roulette'
require 'benchmark'
require 'eventmachine'

REDIS_CONNECTION_POOL_SIZE = 100
ITERATIONS = 10_000

work_order = {'ding dong' => "hello_foreman_" * 100}

EM::Hiredis.reconnect_timeout = 0.01

puts "Redis Connection Pool Size: #{REDIS_CONNECTION_POOL_SIZE}"

times = Benchmark.bm do |x|
  x.report "#{ITERATIONS} ASync Api Read/Writes" do
    EM.run do
      @roullete = WorkerRoulette::WorkerRoulette.start(evented: true)
      @roullete.tradesman_connection_pool.with {|r| r.flushdb}
      @total = 0
      @tradesman = @roullete.tradesman

      ITERATIONS.times do |iteration|
        sender = 'sender_' + iteration.to_s
        foreman = @roullete.foreman(sender)
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
puts "#{(ITERATIONS / times.first.real).to_i} ASync Api Read/Writes per second"
puts "#################"
puts

@roullete.tradesman_connection_pool.with {|r| r.flushdb}

times = Benchmark.bm do |x|
  x.report "#{ITERATIONS * 2} ASync Api Polling Read/Writes" do
    EM.run do
      @processed = 0
      @total     = 0
      @roullete = WorkerRoulette::WorkerRoulette.start(evented: true)
      @roullete.tradesman_connection_pool.with {|r| r.flushdb}
      @total = 0
      @tradesman = @roullete.tradesman
      ITERATIONS.times do |iteration|
        @start ||= Time.now
        sender = 'sender_' + iteration.to_s
        foreman = @roullete.foreman(sender)
        foreman.enqueue_work_order(work_order)
      end
      @tradesman.wait_for_work_orders {@processed += 1; ((@stop = Time.now) && EM.add_timer(1){EM.stop}) if @processed == (ITERATIONS - 1)}
    end
  end
end
puts "#{ITERATIONS * 2 / (@stop - @start)} ASync Api Polling Read/Writes per second"
puts "#################"
puts
@roullete.tradesman_connection_pool.with {|r| r.flushdb}

@roullete = WorkerRoulette::WorkerRoulette.start(size: REDIS_CONNECTION_POOL_SIZE, evented: false)
times = Benchmark.bm do |x|
  puts x.class.name
  x.report "#{ITERATIONS} Sync Api Writes" do
    ITERATIONS.times do |iteration|
      sender = 'sender_' + iteration.to_s
      foreman = @roullete.foreman(sender)
      foreman.enqueue_work_order(work_order)
    end
  end
  @roullete.tradesman_connection_pool.with {|r| r.flushdb}
end
@roullete.tradesman_connection_pool.with {|r| r.flushdb}

puts "#{(ITERATIONS / times.first.real).to_i} Sync Api Writes per second"
puts "#################"
puts
ITERATIONS.times do |iteration|
  sender = 'sender_' + iteration.to_s
  foreman = @roullete.foreman(sender)
  foreman.enqueue_work_order(work_order)
end

times = Benchmark.bm do |x|
  x.report "#{ITERATIONS} Sync Api Reads" do
    ITERATIONS.times do |iteration|
      sender = 'sender_' + iteration.to_s
      tradesman = @roullete.tradesman
      tradesman.work_orders!
    end
  end
end
puts "#{(ITERATIONS / times.first.real).to_i} Sync Api Reads per second"
puts "#################"
puts
@roullete.tradesman_connection_pool.with {|r| r.flushdb}

times = Benchmark.bm do |x|
  x.report "#{ITERATIONS} Sync Api Read/Writes" do
    ITERATIONS.times do |iteration|
      sender = 'sender_' + iteration.to_s
      foreman = @roullete.foreman(sender)
      foreman.enqueue_work_order(work_order)
    end

    ITERATIONS.times do |iteration|
      sender = 'sender_' + iteration.to_s
      tradesman = @roullete.tradesman
      tradesman.work_orders!
    end
  end
end
puts "#{(ITERATIONS / times.first.real).to_i} Sync Api Read/Writes per second"
puts "#################"
puts
@roullete.tradesman_connection_pool.with {|r| r.flushdb}

times = Benchmark.bm do |x|
  x.report "#{ITERATIONS * 2} Sync Api Polling Read/Writes" do
    @roullete = WorkerRoulette::WorkerRoulette.start(size: REDIS_CONNECTION_POOL_SIZE, evented: false)
    ITERATIONS.times do |iteration|
      sender = 'sender_' + iteration.to_s
      foreman = @roullete.foreman(sender)
      foreman.enqueue_work_order(work_order)
      tradesman = @roullete.tradesman
      tradesman.wait_for_work_orders {|m| m}
    end
  end
end
puts "#{(ITERATIONS * 2 / times.first.real).to_i} Sync Api Polling Read/Writes per second"
puts "#################"
puts
@roullete.tradesman_connection_pool.with {|r| r.flushdb}
