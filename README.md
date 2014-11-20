# WorkerRoulette

WorkerRoulette is designed to allow large numbers of unique devices, processes, users, or whatever communicate over individual channels without messing up the order of their messages. 

WorkerRoulette was created to solve two otherwise hard problems:

1) Other messaging solutions (I'm looking at you RabbitMQ) are not designed to  handle very large numbers of queues (millions); because WorkerRoulette is built on top of Redis, we have successfully tested it running with millions of queues. 

2) Other messaging systems assume one (or more) of three things: 
            1. Your message consumers know the routing key of messages they are interested in processing; 
            2. Your messages can wait so that only one consumer is processed at a time; 
            3. You love to write complicated code to put your messages back in order.
Sometimes, none of these things is true and that is where WorkerRoulette comes in.

WorkerRoulette lets you have thousands of competing consumers (distributed over as many machines as you'd like) processing ordered messages from millions of totally unknown message providers. It does all this and ensures that the messages sent from each message provider are processed in exactly the order it sent them.

## Use
```ruby
size_of_connection_pool = 100

#Start it up
#the config takes size for the connection pool size, evented to specify whether to use evented redis or not,
#polling_time dictates the number of seconds to wait before checking the job queue
#(use higher numbers for high traffic systems), then the normal redis config
WorkerRoulette.start(size: size_of_connection_pool, evented: false, host: 'localhost', timeout: 5, db: 1, polling_time: 2)

#Enqueue some work
sender_id = :shady
foreman = WorkerRoulette.foreman(sender_id)
foreman.enqueue_work_order('hello')

#Pull it off (headers always include both the unique id of the sender)
tradesman = WorkerRoulette.tradesman
work_orders = tradesman.work_orders! #drain the queue of the next available sender
work_orders # => {'headers' => {'sender' => :shady}, 'payload' => ['hello']}

#Enqueue some more from someone else
other_sender_id = :the_real_slim_shady
other_foreman = WorkerRoulette.foreman(other_sender_id, 'some_namespace')
other_foreman.enqueue_work_order({'can you get me' => 'the number nine?'}, {'custom' => 'headers'})

#Have the same worker pull that off
work_orders = tradesman.work_orders! #drain the queue of the next available sender
work_orders # => {'headers' => {'sender' => :the_real_slim_shady, 'custom' => 'headers'},
            #     'payload' => [{'can you get me' => 'the number nine?'}]}

#Have your workers wait for work to come in
foreman.enqueue_work_order('will I see you later?')
foreman.enqueue_work_order('can you give me back my dime?')

#And they will pull it off as it comes, as long as it comes. If the job board is empty (ie there is now work to do),
#this method will poll redis every "polling_time" seconds until it finds work,
#at which point it will continue processing jobs until the job board is empty again
tradesman.wait_for_work_orders do |work_orders| #drain the queue of the next available sender
  work_orders.first # => ['will I see you later', 'can you give me back my dime?']
end
```

## Channels
You can also namespace your work orders over a channel, in case you have several sorts of competing consumers who should not step on each other's toes:
```ruby
tradesman         = WorkerRoulette.tradesman('good_channel')
tradesman.should_receive(:work_orders!).and_call_original

good_foreman      = WorkerRoulette.foreman('foreman', 'good_channel')
bad_foreman       = WorkerRoulette.foreman('foreman', 'bad_channel')

good_foreman.enqueue_work_order('some old fashion work')
bad_foreman.enqueue_work_order('evil biddings you should not carry out')

tradesman.wait_for_work_orders do |work|
  work.to_s.should match("some old fashion work") #only got the work from the good foreman
  work.to_s.should_not match("evil")              #channels let us ignore the other's evil orders
end
```

## Performance
Running the performance tests on my laptop, the numbers break down like this:
### Evented
  - Polling: ~11,500 read-write round-trips / second
  - Manual:  ~6,000  read-write round-trips / second

### Non-Evented
  - Polling: ~10,000 read-write round-trips / second
  - Manual:  ~5,500  read-write round-trips / second

To run the perf tests yourself run `bundle exec spec:perf`

## Redis Version
WorkerRoulette uses Redis' lua scripting feature to acheive such high throughput and therefore requires a version of Redis that supports lua scripting (>= Redis 2.6)

##Caveat Emptor
While WorkerRoulette does promise to keep the messages of each consumer processed in order by competing consumers, it does NOT guarantee the order in which the queues themselves will be processed. In general, work is processed in a FIFO order, but for performance reasons this has been left a loose FIFO. For example, if Abdul enqueues some ordered messages ('1', '2', and '3') and then so do Mark and Wanda, Mark's messages may be processed first, then it would likely be Abdul's, and then Wanda's. However, even though Mark jumped the line, Abdul's messages will still be processed in the order he enqueued them ('1', '2', then '3').

## Installation

Add this line to your application's Gemfile:

    gem 'worker_roulette'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install worker_roulette

## Run the specs

    $ bundle exec rake spec:ci

## Run the performance tests

    $ bundle exec rake spec:perf


## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request
