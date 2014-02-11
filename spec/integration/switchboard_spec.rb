require "spec_helper"

describe Switchboard do
  let(:sender) {'katie_80'}
  let(:namespace) {'sixties_telephony'}
  let(:messages) {["hello", "operator"]}
  let(:default_headers) {Hash[headers: {sender: sender}]}
  let(:hello_message) {Hash[payload: "hello"]}
  let(:operator_message) {Hash[payload: "operator"]}
  let(:messages_with_headers) {default_headers.merge({payload: messages})}
  let(:jsonized_messages_with_headers) {[Oj.dump(messages_with_headers)]}

  let(:redis) {Redis.new}
  let(:pool_size) {10}

  before do
    Switchboard.start(pool_size)
    Redis.new.flushdb
  end

  it "should exist" do
    Switchboard.should_not be_nil
  end

  context Operator do
    let(:subject) {Switchboard.operator(namespace, sender)}

    it "should be working on behalf of a sender" do
      subject.sender.should == sender
    end

    it "should be scoped to a namespace" do
      subject.namespace.should == namespace
    end

    it "should be injected with a raw_redis_client so it can do is work" do
      Redis.any_instance.should_receive(:rpush)
      subject.enqueue(:whatever)
    end

    it "should enqueue two messages in the sender's slot in the switchboard" do
      subject.enqueue(messages.first)
      subject.enqueue(messages.last)
      redis.lrange(sender, 0, -1).should == messages.map {|m| Oj.dump(default_headers.merge({payload: m})) }
    end

    it "should enqueue an array of messages without headers in the sender's slot in the switchboard" do
      subject.enqueue_without_headers(messages)
      redis.lrange(sender, 0, -1).should == [Oj.dump(messages)]
    end

    it "should enqueue an array of messages with default headers in the sender's slot in the switchboard" do
      subject.enqueue(messages)
      redis.lrange(sender, 0, -1).should == jsonized_messages_with_headers
    end

    it "should enqueue an array of messages with additional headers in the sender's slot in the switchboard" do
      extra_headers = {foo: :bars}
      subject.enqueue(messages, extra_headers)
      messages_with_headers[:headers].merge!(extra_headers)
      redis.lrange(sender, 0, -1).should == [Oj.dump(messages_with_headers)]
    end

    it "should post the sender's id to the job board with an order number" do
      subject.enqueue(messages.first)
      subject.enqueue(messages.last)
      redis.zrange(subject.job_board_key, 0, -1, with_scores: true).should == [[sender.to_s, messages.length.to_f]]
    end

    it "should post the sender_id and messages transactionally" do
      Redis.any_instance.should_receive(:multi)
      subject.enqueue(messages.first)
    end

    it "should generate sequential order numbers" do
      redis.get(subject.counter_key).should == nil
      subject.enqueue(messages.first)
      redis.get(subject.counter_key).should == "1"
      subject.enqueue(messages.last)
      redis.get(subject.counter_key).should == "2"
    end

    xit "should publish a notification that a new job is ready" do
      result = nil
      redis_subscriber = Redis.new
      redis_subscriber.subscribe(Switchboard::JOB_NOTIFICATIONS) do |on|
        on.subscribe do |channel, subscription|
          subject.enqueue(messages)
        end

        on.message do |channel, notification|
          result = notification
          redis_subscriber.unsubscribe(Switchboard::JOB_NOTIFICATIONS)
        end
     end

      result.should == Switchboard::JOB_NOTIFICATIONS
    end
  end

  context Subscriber do
    let(:operator) {Switchboard.operator(namespace, sender)}
    let(:subject)  {Switchboard.subscriber(namespace)}

    before do
      operator.enqueue(messages)
    end

    it "should be working on behalf of a sender" do
      subject.messages!
      subject.sender.should == sender
    end

    it "should be scoped to a namespace" do
      subject.namespace.should == namespace
    end

    it "should be injected with a redis client so it can do its work" do
      Redis.any_instance.should_receive(:lrange).and_call_original
      subject.messages!
    end

    it "should drain one set of messages from the sender's slot in the switchboard" do
      subject.messages!.should == [messages_with_headers]
      subject.messages!.should == []
      subject.messages!.should == [] #does not throw an error if queue is alreay empty
    end

    it "should drain all the messages from the sender's slot in the switchboard" do
      operator.enqueue(messages)
      subject.messages!.should == [messages_with_headers, messages_with_headers]
      subject.messages!.should == []
      subject.messages!.should == [] #does not throw an error if queue is alreay empty
    end

    it "should take the oldest sender off the job board (FIFO)" do
      oldest_sender = sender.to_s
      most_recent_sender = 'most_recent_sender'
      most_recent_operator = Switchboard.operator(namespace, most_recent_sender)
      most_recent_operator.enqueue(messages)
      redis.zrange(subject.job_board_key, 0, -1).should == [oldest_sender, most_recent_sender]
      subject.messages!
      redis.zrange(subject.job_board_key, 0, -1).should == [most_recent_sender]
    end

    it "should get the sender and message list transactionally" do
      Redis.any_instance.should_receive(:multi).and_call_original
      subject.messages!
    end

    it "should get the messages from the next sender's slot when a new job is ready" do
      subject.messages!
      subject.should_receive(:messages!).and_call_original
      publisher = -> {operator.enqueue(messages)}
      subject.wait_for_messages(publisher) do |redis_messages|
        redis_messages.should == [messages_with_headers]
      end
    end

    it "should checkout a readlock for a queue and put it back when its done processing; lock should expire after 5 minutes?"
    it "should eves drop on the job board"

    context "Failure" do
      it "should not put the sender_id and messages back if processing fails bc new messages may have been processed while that process failed" do; end
    end

    context "Concurrent Access" do
      it "should pool its connections" do
        Array.new(100) do
          Thread.new {Switchboard.subscriber_connection_pool.with {|pooled_redis| pooled_redis.get("foo")}}
        end.each(&:join)
        Switchboard.subscriber_connection_pool.with do |pooled_redis|
          pooled_redis.info["connected_clients"].to_i.should > (pool_size)
        end
      end

      #This may be fixed soon (10 Feb 2014 - https://github.com/redis/redis-rb/pull/389 and https://github.com/redis/redis-rb/issues/364)
      it "should not be fork() proof -- forking reconnects need to be handled in the calling code (until redis gem is udpated, then we should be fork-proof)" do
        Switchboard.start(1)
        Switchboard.subscriber_connection_pool.with {|pooled_redis| pooled_redis.get("foo")}
        fork do
          expect {Switchboard.subscriber_connection_pool.with {|pooled_redis| pooled_redis.get("foo")}}.to raise_error(Redis::InheritedError)
        end
      end

      it "should use optionally non-blocking I/O" do
        expect {Switchboard.start(1, :driver => :synchrony)}.not_to raise_error
      end
    end
  end
end