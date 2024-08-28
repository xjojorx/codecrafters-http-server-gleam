import gleam/io

import gleam/bytes_builder
import gleam/list
import gleam/string
import gleam/int
import gleam/bit_array
import gleam/dict.{type Dict}

import gleam/erlang/process
import gleam/option.{None, Some, type Option}
import gleam/otp/actor
import glisten
import argv
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

type HttpResponse {
  HttpResponse(status_code: HttpStatus, headers: List(HttpHeader), body: String)
}
type HttpMethod{
  Get
  Post
  Put
  Patch
  Delete
  Options
}
type HttpRequest {
  HttpRequest(method: HttpMethod, target: String, headers: List(HttpHeader), body: String)
}
type RequestLine {
  RequestLine(method: HttpMethod, target: String, version: String)
}

type Configuration {
  Configuration(port: Int, files_path: Option(String))
}
type State{
  State(conf: Configuration)
}

pub fn main() {
  // You can use print statements as follows for debugging, they'll be visible when running tests.
  io.println("Logs from your program will appear here!")

  let args = argv.load().arguments
  let conf = get_configuration(args)
  let state = State(conf)

  let assert Ok(_) =
    glisten.handler(fn(_conn) { #(state, None) }, fn(msg, state, conn) {
      io.println("Received message!")
      let assert Ok(response) = handle_package(msg, state)
      let _ = glisten.send(conn, response)
      actor.continue(state)
    })
    // |> glisten.serve(4221)
    |> glisten.serve(conf.port)

  process.sleep_forever()
}

fn get_configuration(args: List(String)) -> Configuration {
  let named_args = get_named_args(args)
  let default_port = 4221
  let port = case dict.get(named_args, "port") {
    Ok(val) -> case int.parse(val) {
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
fn do_get_named_args(args: List(String), curr: Dict(String, String)) -> Dict(String, String) {
  case args {
    [] -> curr
    ["--"<>key, val, ..rest] -> do_get_named_args(rest, dict.insert(curr, key, val)) 
    [_, ..rest] -> do_get_named_args(rest, curr)
  }
}

fn handle_package(message: glisten.Message(Nil), state: State) {
  case message {
    glisten.Packet(msg_bits) -> {
      let assert Ok(msg_str) = bit_array.to_string(msg_bits)

      let response = handle_request(msg_str, state)
      let str_res = format_response(response) |> io.debug

      let res = bytes_builder.from_string(str_res)
      Ok(res)
    }
    _ -> Error(Nil)
  }
}

fn format_response(response: HttpResponse) -> String {
  let status_line = status_str(response.status_code)
  let headers =
    response.headers
    |> list.map(header_str)

  let body_bytes = bit_array.from_string(response.body)
  let body_size = bit_array.byte_size(body_bytes)
  let headers = ["Content-Length: "<>int.to_string(body_size), ..headers]
  let headers_str = string.join(headers, "\r\n")
    <> "\r\n" // end of last header

  "HTTP/1.1 " <> status_line <> "\r\n" 
    <> headers_str <> "\r\n" //crlf to end header section
    <> response.body 
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

fn handle_request(request: String,state: State) -> HttpResponse {
  let request = parse_request(request)
  case request.method {
    Get -> handle_get(request, state)
    Post -> handle_post(request, state)
    _ -> panic
  }
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
fn parse_header(header_str: String) -> HttpHeader{
  let assert Ok(#(key, val)) = header_str
  |> string.split_once(":")

  HttpHeader(string.trim(key), string.trim(val))
}


fn handle_get(request: HttpRequest,state: State) -> HttpResponse {
  case request.target {
    "/" -> HttpResponse(Success, [], "")
    "/echo/"<>rest -> handle_echo(request, rest)
    "/user-agent"|"/user-agent/"  -> handle_user_agent(request)
    "/files/"<>path -> handle_files(request, path, state.conf)
    _ -> HttpResponse(NotFound, [], "")
  }
}

fn handle_echo(_request: HttpRequest, content: String) -> HttpResponse  {
  HttpResponse(Success, [HttpHeader("Content-Type", "text/plain")], content)
}

fn handle_user_agent(request: HttpRequest)  -> HttpResponse {
  let header_res = list.find(request.headers, fn(h)  {
    let HttpHeader(key, _val) = h
    key == "User-Agent"
  })

  case header_res {
    Ok(HttpHeader(_, val)) -> HttpResponse(Success, [HttpHeader("Content-Type", "text/plain")], val)
    _ -> HttpResponse(NotFound, [], "")
  }
}

fn handle_files(_request: HttpRequest, path: String, config: Configuration) -> HttpResponse {
  let assert Some(base_path) = config.files_path
  let path = case string.ends_with(base_path, "/"){
    True -> base_path<>path
    False -> base_path<>"/"<>path
  } |> io.debug
  case simplifile.is_file(path) {
    Error(_) -> HttpResponse(ServerError, [], "")
    Ok(False) -> HttpResponse(NotFound, [], "")
    Ok(True) -> case simplifile.read(path) {
      Ok(content) -> HttpResponse(Success, [HttpHeader("Content-Type", "application/octet-stream")], content)
      Error(_) -> HttpResponse(ServerError, [], "")
    }
  }
}

fn handle_post(request: HttpRequest, state: State) -> HttpResponse {
  case request.target {
    "/files/"<>filename -> handle_post_file(request, filename, state.conf)
    _ -> HttpResponse(NotFound, [], "")

  }

}
fn handle_post_file(request: HttpRequest, filename: String, config: Configuration) -> HttpResponse {
  let assert Some(base_path) = config.files_path
  let path = case string.ends_with(base_path, "/"){
    True -> base_path<>filename
    False -> base_path<>"/"<>filename
  } |> io.debug
  case simplifile.write(path, request.body) {
    Ok(_) -> HttpResponse(Created, [], "")
    Error(_) -> HttpResponse(ServerError, [], "")
  }
}
