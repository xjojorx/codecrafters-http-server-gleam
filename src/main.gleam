import gleam/io
import glisten/tcp

import gleam/bit_array
import gleam/bytes_builder
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/string

import argv
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import glisten.{type Connection}
import simplifile

type HttpHeader {
  HttpHeader(String, String)
}

type HttpStatus {
  Success
  Created
  // ClientError
  NotFound
  // Redirect
  ServerError
}

type ResponseBody {
  EmptyBody
  StringBody(String)
  BinaryBody(BitArray)
}

type HttpResponse {
  HttpResponse(
    status_code: HttpStatus,
    headers: List(HttpHeader),
    body: ResponseBody,
    is_stop: Bool,
  )
}

type HttpMethod {
  Get
  Post
  Put
  Patch
  Delete
  Options
}

type HttpRequest {
  HttpRequest(
    method: HttpMethod,
    target: String,
    headers: List(HttpHeader),
    body: String,
  )
}

type RequestLine {
  RequestLine(method: HttpMethod, target: String, version: String)
}

type Configuration {
  Configuration(port: Int, files_path: Option(String))
}

type State {
  State(conf: Configuration, conn: Connection(Nil))
}

pub fn main() {
  // You can use print statements as follows for debugging, they'll be visible when running tests.
  io.println("Logs from your program will appear here!")

  let args = argv.load().arguments
  let conf = get_configuration(args)
  // let state = State(conf)

  let assert Ok(_) =
    glisten.handler(
      fn(conn) { #(State(conf, conn), None) },
      fn(msg, state, conn) {
        io.println("Received message!")
        let assert Ok(#(response, is_stop)) = handle_package(msg, state)
        let _ = glisten.send(conn, response)
    io.debug( is_stop)

        let _ = case is_stop {
          True -> {
            tcp.close(state.conn)
          }
          False -> Ok(Nil)
        }
        actor.continue(state)
      },
    )
    // |> glisten.serve(4221)
    |> glisten.with_close(fn(_) { io.println("Connection closed!") })
    |> glisten.serve(conf.port)

  process.sleep_forever()
}

fn get_configuration(args: List(String)) -> Configuration {
  let named_args = get_named_args(args)
  let default_port = 4221
  let port = case dict.get(named_args, "port") {
    Ok(val) ->
      case int.parse(val) {
        Ok(n) -> n
        _ -> default_port
      }
    _ -> default_port
  }
  let files_dir = case dict.get(named_args, "directory") {
    Ok(val) -> Some(val)
    _ -> None
  }

  Configuration(port, files_dir)
}

fn get_named_args(args: List(String)) -> Dict(String, String) {
  do_get_named_args(args, dict.new())
}

fn do_get_named_args(
  args: List(String),
  curr: Dict(String, String),
) -> Dict(String, String) {
  case args {
    [] -> curr
    ["--" <> key, val, ..rest] ->
      do_get_named_args(rest, dict.insert(curr, key, val))
    [_, ..rest] -> do_get_named_args(rest, curr)
  }
}

fn handle_package(message: glisten.Message(Nil), state: State) {
  case message {
    glisten.Packet(msg_bits) -> {
      let assert Ok(msg_str) = bit_array.to_string(msg_bits)

      let response = handle_request(msg_str, state)
      let res = format_response(response) |> io.debug

      Ok(res)
    }
    _ -> Error(Nil)
  }
}

fn format_response(
  response: HttpResponse,
) -> #(bytes_builder.BytesBuilder, Bool) {
  let status_line = status_str(response.status_code)
  let headers =
    response.headers
    |> list.map(header_str)

  let body_bits = case response.body {
    StringBody(str) -> bit_array.from_string(str)
    BinaryBody(bits) -> bits
    EmptyBody -> <<>>
  }
  let body_size = bit_array.byte_size(body_bits)
  let headers = ["Content-Length: " <> int.to_string(body_size), ..headers]
  let headers_str = string.join(headers, "\r\n") <> "\r\n"
  // end of last header

  let bodyless_response =
    "HTTP/1.1 " <> status_line <> "\r\n" <> headers_str <> "\r\n"
  //crlf to end header section

  let bytes =
    bodyless_response
    |> bytes_builder.from_string
    |> bytes_builder.append(body_bits)

  #(bytes, response.is_stop)
}

fn status_str(code: HttpStatus) -> String {
  case code {
    Success -> "200 OK"
    NotFound -> "404 Not Found"
    ServerError -> "500 Server Error"
    Created -> "201 Created"
  }
}

fn header_str(header: HttpHeader) -> String {
  let HttpHeader(key, val) = header
  key <> ": " <> val
}

fn handle_request(request: String, state: State) -> HttpResponse {
  let request = parse_request(request)
  case request.method {
    Get -> handle_get(request, state)
    Post -> handle_post(request, state)
    _ -> panic
  }
  |> apply_close_header(request)
  |> apply_compression(request, state)
}

fn parse_request(raw_request: String) -> HttpRequest {
  io.debug(raw_request)
  let parts = string.split(raw_request, "\r\n")
  let assert [req_line, ..rest] = parts |> io.debug
  let RequestLine(method, path, _version) = parse_request_line(req_line)

  let #(headers, body) = parse_headers_body(rest)

  HttpRequest(method, path, headers, body)
  |> io.debug
}

fn parse_request_line(request_line: String) {
  let parts = string.split(request_line, " ")
  let assert [method, path, version, ..] = parts |> io.debug
  let method = parse_method(method)
  let path = string.trim(path)

  RequestLine(method, path, version)
}

fn parse_method(method: String) -> HttpMethod {
  case method {
    "GET" -> Get
    "POST" -> Post
    "PUT" -> Put
    "PATCH" -> Patch
    "DELETE" -> Delete
    "OPTIONS" -> Options
    _ -> panic
  }
}

fn parse_headers_body(parts: List(String)) {
  do_parse_headers_body(parts, [])
}

fn do_parse_headers_body(parts: List(String), curr: List(HttpHeader)) {
  case parts {
    [b] -> #(curr, b)
    ["", ..t] -> do_parse_headers_body(t, curr)
    [h, ..t] -> do_parse_headers_body(t, [parse_header(h), ..curr])
    [] -> panic
  }
}

fn parse_header(header_str: String) -> HttpHeader {
  let assert Ok(#(key, val)) =
    header_str
    |> string.split_once(":")

  HttpHeader(string.trim(key), string.trim(val))
}

fn handle_get(request: HttpRequest, state: State) -> HttpResponse {
  case request.target {
    "/" -> HttpResponse(Success, [], EmptyBody, False)
    "/echo/" <> rest -> handle_echo(request, rest)
    "/user-agent" | "/user-agent/" -> handle_user_agent(request)
    "/files/" <> path -> handle_files(request, path, state.conf)
    _ -> HttpResponse(NotFound, [], EmptyBody, False)
  }
}

fn handle_echo(_request: HttpRequest, content: String) -> HttpResponse {
  HttpResponse(
    Success,
    [HttpHeader("Content-Type", "text/plain")],
    StringBody(content),
    False,
  )
}

fn handle_user_agent(request: HttpRequest) -> HttpResponse {
  let header_res =
    list.find(request.headers, fn(h) {
      let HttpHeader(key, _val) = h
      key == "User-Agent"
    })

  case header_res {
    Ok(HttpHeader(_, val)) ->
      HttpResponse(
        Success,
        [HttpHeader("Content-Type", "text/plain")],
        StringBody(val),
        False,
      )
    _ -> HttpResponse(NotFound, [], EmptyBody, False)
  }
}

fn handle_files(
  _request: HttpRequest,
  path: String,
  config: Configuration,
) -> HttpResponse {
  let assert Some(base_path) = config.files_path
  let path =
    case string.ends_with(base_path, "/") {
      True -> base_path <> path
      False -> base_path <> "/" <> path
    }
    |> io.debug
  case simplifile.is_file(path) {
    Error(_) -> HttpResponse(ServerError, [], EmptyBody, False)
    Ok(False) -> HttpResponse(NotFound, [], EmptyBody, False)
    Ok(True) ->
      case simplifile.read(path) {
        Ok(content) ->
          HttpResponse(
            Success,
            [HttpHeader("Content-Type", "application/octet-stream")],
            StringBody(content),
            False,
          )
        Error(_) -> HttpResponse(ServerError, [], EmptyBody, False)
      }
  }
}

fn handle_post(request: HttpRequest, state: State) -> HttpResponse {
  case request.target {
    "/files/" <> filename -> handle_post_file(request, filename, state.conf)
    _ -> HttpResponse(NotFound, [], EmptyBody, False)
  }
}

fn handle_post_file(
  request: HttpRequest,
  filename: String,
  config: Configuration,
) -> HttpResponse {
  let assert Some(base_path) = config.files_path
  let path =
    case string.ends_with(base_path, "/") {
      True -> base_path <> filename
      False -> base_path <> "/" <> filename
    }
    |> io.debug
  case simplifile.write(path, request.body) {
    Ok(_) -> HttpResponse(Created, [], EmptyBody, False)
    Error(_) -> HttpResponse(ServerError, [], EmptyBody, False)
  }
}

fn apply_compression(
  response: HttpResponse,
  request: HttpRequest,
  _state: State,
) -> HttpResponse {
  let accepted = client_accepts_compression(request)
  let selected = select_compresion(accepted)
  case selected {
    Some("gzip") -> gzip_response(response)
    _ -> response
  }
}

fn client_accepts_compression(request: HttpRequest) -> List(String) {
  let header_val =
    request.headers
    |> list.find_map(fn(h) {
      let HttpHeader(key, val) = h
      case key == "Accept-Encoding" {
        True -> Ok(val)
        False -> Error(Nil)
      }
    })
  case header_val {
    Ok(val) -> string.split(val, ",") |> list.map(fn(s) { string.trim(s) })
    Error(_) -> []
  }
}

fn select_compresion(client_accepted: List(String)) -> Option(String) {
  let supported = ["gzip"]
  let valid_compressions =
    list.filter(supported, fn(c) { list.contains(client_accepted, c) })
  case valid_compressions {
    [] -> None
    [x] -> Some(x)
    l ->
      case list.first(l) {
        Ok(val) -> Some(val)
        Error(_) -> None
      }
  }
}

fn gzip_response(response: HttpResponse) -> HttpResponse {
  let bits = case response.body {
    EmptyBody -> <<>>
    StringBody(str) -> bit_array.from_string(str)
    BinaryBody(bits) -> bits
  }
  let compressed = gzip(bits)
  HttpResponse(
    response.status_code,
    [HttpHeader("Content-Encoding", "gzip"), ..response.headers],
    BinaryBody(compressed),
    False,
  )
}

@external(erlang, "zlib", "gzip")
fn gzip(data: BitArray) -> BitArray

fn apply_close_header(
  response: HttpResponse,
  request: HttpRequest,
) -> HttpResponse {
  let close =
    list.find(request.headers, fn(x) {
      case x {
        HttpHeader("Connection", "close") -> True
        _ -> False
      }
    })
  case close {
    Error(_) -> HttpResponse(..response, headers: [HttpHeader("Connection", "keep-alive"), ..response.headers], is_stop: False)
    Ok(h) ->
      HttpResponse(..response, headers: [h, ..response.headers], is_stop: True)
  }
}
