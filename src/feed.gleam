import dashboard
import gleam/bytes_tree
import gleam/erlang/application
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/option.{type Option, None, Some}
import lustre
import lustre/attribute
import lustre/element.{element}
import lustre/element/html.{html}
import lustre/server_component
import mist.{
  type Connection, type ResponseData, type WebsocketConnection,
  type WebsocketMessage,
}

pub fn main() {
  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      case request.path_segments(req) {
        ["feed"] ->
          mist.websocket(
            request: req,
            on_init: socket_init,
            on_close: socket_close,
            handler: socket_update,
          )

        ["lustre", "runtime.mjs"] -> {
          let assert Ok(priv) = application.priv_directory("lustre")
          let path = priv <> "/static/lustre-server-component.mjs"

          case mist.send_file(path, offset: 0, limit: None) {
            Ok(script) -> {
              response.new(200)
              |> response.prepend_header(
                "content-type",
                "application/javascript",
              )
              |> response.set_body(script)
            }
            Error(_) -> {
              response.new(404)
              |> response.set_body(mist.Bytes(bytes_tree.new()))
            }
          }
        }
        _ ->
          response.new(200)
          |> response.prepend_header("content-type", "text/html")
          |> response.set_body(
            html([], [
              html.head([], [
                html.link([
                  attribute.rel("stylesheet"),
                  attribute.href(
                    "https://cdn.jsdelivr.net/gh/lustre-labs/ui/priv/styles.css",
                  ),
                ]),
                html.script(
                  [
                    attribute.type_("module"),
                    attribute.src("/lustre/runtime.mjs"),
                  ],
                  "",
                ),
              ]),
              html.body([], [
                element(
                  "lustre-server-component",
                  [
                    server_component.route("/feed"),
                  ],
                  [],
                ),
              ]),
            ])
            |> element.to_document_string_tree
            |> bytes_tree.from_string_tree
            |> mist.Bytes,
          )
      }
    }
    |> mist.new
    |> mist.bind("localhost")
    |> mist.port(3000)
    |> mist.start

  process.sleep_forever()
}

pub type DashboardSocketMessage =
  server_component.ClientMessage(dashboard.Msg)

type DashboardSocket {
  DashboardSocket(
    component: lustre.Runtime(dashboard.Msg),
    self: Subject(DashboardSocketMessage),
  )
}

fn socket_init(
  _,
) -> #(DashboardSocket, Option(Selector(DashboardSocketMessage))) {
  let dashboard = dashboard.app()
  let assert Ok(component) =
    lustre.start_server_component(dashboard, dashboard.Dashboard([]))

  let self = process.new_subject()
  let selector = process.new_selector() |> process.select(self)

  server_component.register_subject(self)
  |> lustre.send(to: component)

  #(DashboardSocket(component:, self:), Some(selector))
}

fn socket_update(
  state: DashboardSocket,
  msg: WebsocketMessage(DashboardSocketMessage),
  conn: WebsocketConnection,
) {
  case msg {
    mist.Text(json) -> {
      case json.parse(json, server_component.runtime_message_decoder()) {
        Ok(runtime_message) -> lustre.send(state.component, runtime_message)
        Error(_) -> Nil
      }

      mist.continue(state)
    }

    mist.Binary(_) -> mist.continue(state)
    mist.Custom(patch) -> {
      let json = server_component.client_message_to_json(patch)
      let assert Ok(_) = mist.send_text_frame(conn, json.to_string(json))
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn socket_close(state: DashboardSocket) {
  lustre.shutdown()
  |> lustre.send(state.component, _)
}
