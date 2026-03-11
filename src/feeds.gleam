import gleam/erlang/process

import gleam/list
import gleam/otp/actor

pub opaque type Feed(feed_msg) {
  Feed(subject: process.Subject(FeedOptions(feed_msg)))
}

pub type PollStatus(feed_msg) {
  SourceChanged(posts: feed_msg)
  NoChange
}

pub fn subscribe(
  feed: Feed(feed_msg),
  subscribing_subject: process.Subject(feed_msg),
) {
  process.send(feed.subject, Subscribe(subscribing_subject))
}

type FeedOptions(feed_msg) {
  Subscribe(subscriber: process.Subject(feed_msg))
  PollResponse(update: PollStatus(feed_msg))
}

type FeedState(feed_msg) {
  FeedState(
    poll_channel: process.Subject(Poll),
    polling_rate: Int,
    subscribers: List(process.Subject(feed_msg)),
  )
}

type Poll {
  Poll
}

pub fn start_feed(
  with_polling_data init_state: poller_state,
  poll_handler poller: fn(poller_state) -> #(poller_state, PollStatus(feed_msg)),
) -> Feed(feed_msg) {
  let assert Ok(feed_actor) =
    actor.new_with_initialiser(100, fn(feed_subject) {
      let poll_status_subject = process.new_subject()

      let assert Ok(poll_actor_result) =
        actor.new(PollingState(poll_status_subject, init_state))
        |> actor.on_message(poll_actor(poller))
        |> actor.start
      let poll_subject = poll_actor_result.data

      let poll_response_selector =
        process.new_selector()
        |> process.select_map(poll_status_subject, PollResponse)
        |> process.select(feed_subject)

      process.send(poll_subject, Poll)

      actor.initialised(FeedState(poll_subject, 60 * 1000, []))
      |> actor.selecting(poll_response_selector)
      |> actor.returning(feed_subject)
      |> Ok
    })
    |> actor.on_message(
      fn(state: FeedState(feed_msg), msg: FeedOptions(feed_msg)) {
        echo "Feed received message"
        case msg {
          Subscribe(subscriber) -> {
            echo "Subscribing"
            actor.continue(
              FeedState(..state, subscribers: [subscriber, ..state.subscribers]),
            )
          }
          PollResponse(response) -> {
            echo "Poll responded with:"
            echo response
            case response {
              NoChange -> Nil
              SourceChanged(changes) ->
                state.subscribers |> list.each(process.send(_, changes))
            }
            process.send_after(state.poll_channel, state.polling_rate, Poll)
            actor.continue(state)
          }
        }
      },
    )
    |> actor.start

  Feed(subject: feed_actor.data)
}

type PollingState(poll_fn_state, feed_msg) {
  PollingState(
    listener: process.Subject(PollStatus(feed_msg)),
    poller_state: poll_fn_state,
  )
}

type PollActorGenerator(poller_state, feed_msg) =
  fn(PollingState(poller_state, feed_msg), Poll) ->
    actor.Next(PollingState(poller_state, feed_msg), Poll)

fn poll_actor(
  poll_fn: fn(poller_state) -> #(poller_state, PollStatus(feed_msg)),
) -> PollActorGenerator(poller_state, feed_msg) {
  fn(state: PollingState(poller_state, feed_msg), should_poll) {
    case should_poll {
      Poll -> {
        let #(new_state, msg) = poll_fn(state.poller_state)
        process.send(state.listener, msg)

        actor.continue(PollingState(..state, poller_state: new_state))
      }
    }
  }
}
