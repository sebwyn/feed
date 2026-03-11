import birl
import feeds
import gleam/bool
import gleam/dynamic/decode
import gleam/float
import gleam/hackney
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option.{type Option, Some}
import gleam/order

const reddit_api: String = "https://api.reddit.com/"

pub fn start_feed(subreddit: String) {
  feeds.start_feed(RedditPollingState(subreddit, option.None), reddit_poller)
}

type RedditPollingState {
  RedditPollingState(subreddit: String, last_post_time: Option(birl.Time))
}

type RedditPollResponse =
  List(String)

fn reddit_poller(
  state: RedditPollingState,
) -> #(RedditPollingState, feeds.PollStatus(RedditPollResponse)) {
  let #(posts, new_last_post_time) =
    get_new_posts(
      from_subreddit: state.subreddit,
      after_time: state.last_post_time,
    )

  echo "About to send poll results!"
  let poll_response = case list.is_empty(posts) {
    True -> feeds.NoChange
    False -> feeds.SourceChanged(posts)
  }

  let new_state =
    RedditPollingState(..state, last_post_time: new_last_post_time)

  #(new_state, poll_response)
}

type Post {
  Post(id: String, title: String, created_utc: birl.Time)
}

type Listing {
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
