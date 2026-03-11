import feeds
import gleam/erlang/process
import gleam/list
import gleam/string
import lustre
import lustre/effect
import lustre/element/html
import lustre/server_component

pub type Dashboard {
  Dashboard(posts: List(String))
}

pub type Msg {
  FeedUpdated(posts: List(String))
}

pub fn app() {
  lustre.application(init, update, view)
}

fn init(_model: Dashboard) -> #(Dashboard, effect.Effect(Msg)) {
  #(
    Dashboard([]),
    server_component.select(fn(_, subject: process.Subject(List(String))) {
      feeds.start_feed(
        feeds.create_reddit_polling_state("politics"),
        feeds.reddit_poller,
      )
      |> process.send(feeds.Subscribe(subject))

      process.new_selector()
      |> process.select_map(subject, FeedUpdated)
    }),
  )
}

fn update(model: Dashboard, msg: Msg) -> #(Dashboard, effect.Effect(Msg)) {
  case msg {
    FeedUpdated(posts) -> {
      echo "Received new posts: " <> string.join(posts, ",")
      #(Dashboard(list.flatten([posts, model.posts])), effect.none())
    }
  }
}

fn view(dashboard: Dashboard) {
  html.div(
    [],
    dashboard.posts
      |> list.map(fn(post_title) { html.h1([], [html.text(post_title)]) }),
  )
}
