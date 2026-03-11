import birl
import gleam/bool
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/float
import gleam/hackney
import gleam/http/request
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor

pub type FeedOptions(feed_msg) {
  Subscribe(subscriber: process.Subject(feed_msg))
  PollResponse(update: PollStatus(feed_msg))
}

pub type FeedState(feed_msg) {
  FeedState(
    poll_channel: process.Subject(Poll),
    polling_rate: Int,
    subscribers: List(process.Subject(feed_msg)),
  )
}

pub type Poll {
  Poll
}

pub type PollStatus(feed_msg) {
  SourceChanged(posts: feed_msg)
  NoChange
}

pub fn start_feed(
  with_polling_data state: fn(process.Subject(PollStatus(feed_msg))) ->
    feed_state,
  poll_handler poller: fn(feed_state, Poll) -> actor.Next(feed_state, Poll),
) -> process.Subject(FeedOptions(feed_msg)) {
  let assert Ok(feed_actor) =
    actor.new_with_initialiser(100, fn(feed_subject) {
      let poll_status_subject = process.new_subject()

      let assert Ok(poll_actor_result) =
        actor.new(state(poll_status_subject))
        |> actor.on_message(poller)
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

  feed_actor.data
}

const reddit_api: String = "https://api.reddit.com/"

pub type RedditPollingState {
  RedditPollingState(
    listener: process.Subject(PollStatus(List(String))),
    subreddit: String,
    last_post_time: Option(birl.Time),
  )
}

pub fn create_reddit_polling_state(
  subreddit: String,
) -> fn(process.Subject(PollStatus(List(String)))) -> RedditPollingState {
  fn(subject) { RedditPollingState(subject, subreddit, None) }
}

pub fn reddit_poller(
  state: RedditPollingState,
  should_poll: Poll,
) -> actor.Next(RedditPollingState, Poll) {
  case should_poll {
    Poll -> {
      let #(posts, new_last_post_time) =
        get_new_posts(
          from_subreddit: state.subreddit,
          after_time: state.last_post_time,
        )

      echo "About to send poll results!"
      let poll_response = case list.is_empty(posts) {
        True -> NoChange
        False -> SourceChanged(posts)
      }
      process.send(state.listener, poll_response)
      actor.continue(
        RedditPollingState(..state, last_post_time: new_last_post_time),
      )
    }
  }
}

pub type Post {
  Post(id: String, title: String, created_utc: birl.Time)
}

pub type Listing {
  Listing(children: List(Post))
}

fn get_new_posts(
  from_subreddit subreddit: String,
  after_time previous_time: Option(birl.Time),
) -> #(List(String), Option(birl.Time)) {
  let url = reddit_api <> "r/" <> subreddit <> "/new?sort=new"
  let assert Ok(req) = request.to(url)
  let assert Ok(resp) = hackney.send(req)
  let assert Ok(listing) = json.parse(resp.body, decode_listing())

  let filter_posts_before = previous_time |> option.unwrap(birl.unix_epoch())

  let new_posts =
    listing.children
    |> list.filter(fn(p) {
      birl.compare(p.created_utc, filter_posts_before) == order.Gt
    })

  let recent_post_time = case list.first(new_posts) {
    Ok(post) -> Some(post.created_utc)
    _ -> previous_time
  }

  let post_titles = new_posts |> list.map(fn(p) { p.title })
  #(post_titles, recent_post_time)
}

fn decode_post() -> decode.Decoder(Post) {
  use kind <- decode.field("kind", decode.string)

  use <- bool.guard(
    kind != "t3",
    Post("", "", birl.unix_epoch())
      |> decode.failure("Expected a post object! " <> kind),
  )

  let data_decoder = {
    use id <- decode.field("id", decode.string)
    use title <- decode.field("title", decode.string)
    use created_utc_float <- decode.field("created_utc", decode.float)
    let created_utc = created_utc_float |> float.round |> birl.from_unix
    decode.success(Post(id, title, created_utc))
  }

  decode.field("data", data_decoder, decode.success)
}

fn decode_listing() -> decode.Decoder(Listing) {
  use kind <- decode.field("kind", decode.string)
  use <- bool.guard(
    kind != "Listing",
    Listing([]) |> decode.failure("Reddit object is not a listing! " <> kind),
  )

  let data_decoder = {
    use children <- decode.field("children", decode.list(decode_post()))
    decode.success(Listing(children))
  }

  decode.field("data", data_decoder, decode.success)
}
