import birl
import gleam/dynamic
import gleam/float
import gleam/hackney
import gleam/http/request
import gleam/io
import gleam/iterator
import gleam/json
import gleam/result
import gleam/string

pub type GenericRedditObject {
  GenericRedditObject(kind: String, data: dynamic.Dynamic)
}

pub type RedditObject {
  Listing(children: List(RedditObject))
  //Post is 't3' type in reddit JSON
  Post(id: String, title: String, created_utc: birl.Time)
}

pub fn main() {
  let posts = get_new_posts_from_subreddit("programming")

  let post_title = fn(posts: iterator.Iterator(RedditObject)) -> iterator.Iterator(
    String,
  ) {
    posts
    |> iterator.filter_map(fn(obj) {
      case obj {
        Post(title: title, ..) -> Ok(title)
        _ -> Error(Nil)
      }
    })
  }

  let post_names =
    iterator.from_list(posts)
    |> post_title
    |> iterator.to_list

  io.println(string.join(post_names, "\n"))
}

const reddit_api: String = "https://api.reddit.com/"

fn decode_reddit_object(
  dynamic_json: dynamic.Dynamic,
) -> Result(RedditObject, List(dynamic.DecodeError)) {
  let generic_reddit_decoder =
    dynamic.decode2(
      GenericRedditObject,
      dynamic.field("kind", of: dynamic.string),
      dynamic.field("data", of: dynamic.dynamic),
    )

  let listing_decoder =
    dynamic.decode1(
      Listing,
      dynamic.field("children", dynamic.list(decode_reddit_object)),
    )

  let post_decoder =
    dynamic.decode3(
      Post,
      dynamic.field("id", dynamic.string),
      dynamic.field("title", dynamic.string),
      dynamic.field("created_utc", fn(d) {
        result.map(dynamic.float(d), fn(float_utc) {
          let int_utc = float.round(float_utc)
          birl.from_unix(int_utc)
        })
      }),
    )

  case generic_reddit_decoder(dynamic_json) {
    Ok(GenericRedditObject("Listing", data: data)) -> listing_decoder(data)
    Ok(GenericRedditObject("t3", data: data)) -> post_decoder(data)
    Ok(GenericRedditObject(..)) -> Error([])
    Error(_) -> Error([])
  }
}

fn get_new_posts_from_subreddit(subreddit: String) -> List(RedditObject) {
  let url = reddit_api <> "r/" <> subreddit <> "/new?sort=new"
  let assert Ok(req) = request.to(url)
  let assert Ok(resp) = hackney.send(req)
  let assert Ok(subreddit_response) =
    json.decode(resp.body, using: decode_reddit_object)

  let assert Listing(listing_results) = subreddit_response

  listing_results
}
