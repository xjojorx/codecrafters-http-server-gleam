import gleam/io

import gleam/bytes_builder
import gleam/list
import gleam/string
import gleam/int
import gleam/bit_array

import gleam/erlang/process
import gleam/option.{None}
import gleam/otp/actor
import glisten

type HttpHeader {
  HttpHeader(String, String)
}

type HttpStatus {
  Success
  // ClientError
  NotFound
  // Redirect
  // ServerError
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

pub fn main() {
  // You can use print statements as follows for debugging, they'll be visible when running tests.
  io.println("Logs from your program will appear here!")

  let assert Ok(_) =
    glisten.handler(fn(_conn) { #(Nil, None) }, fn(msg, state, conn) {
      io.println("Received message!")
      let assert Ok(response) = handle_package(msg)
      let _ = glisten.send(conn, response)
      actor.continue(state)
    })
    |> glisten.serve(4221)

  process.sleep_forever()
}

fn handle_package(message: glisten.Message(Nil)) {
  case message {
    glisten.Packet(msg_bits) -> {
      let assert Ok(msg_str) = bit_array.to_string(msg_bits)

      let response = handle_request(msg_str)
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
  }
}

fn header_str(header: HttpHeader) -> String {
  let HttpHeader(key, val) = header
  key <> ": " <> val
}

fn handle_request(request: String) -> HttpResponse {
  let request = parse_request(request)
  case request.method {
    Get -> handle_get(request)
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


fn handle_get(request: HttpRequest) -> HttpResponse {
  case request.target {
    "/" -> HttpResponse(Success, [], "")
    _ -> HttpResponse(NotFound, [], "")
  }
  
}
