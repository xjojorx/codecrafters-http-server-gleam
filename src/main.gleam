import gleam/io

import gleam/bytes_builder
import gleam/list
import gleam/string

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
  // Redirect
  // ServerError
}

type HttpResponse {
  HttpResponse(status_code: HttpStatus, headers: List(HttpHeader), body: String)
}

pub fn main() {
  // You can use print statements as follows for debugging, they'll be visible when running tests.
  io.println("Logs from your program will appear here!")

  let assert Ok(_) =
    glisten.handler(fn(_conn) { #(Nil, None) }, fn(_msg, state, conn) {
      io.println("Received message!")
      let _ = glisten.send(conn, handle_request("msg"))
      actor.continue(state)
    })
    |> glisten.serve(4221)

  process.sleep_forever()
}

fn handle_request(_message: String) {
  let response = HttpResponse(Success, [], "")
  let str_res = format_response(response)

  bytes_builder.from_string(str_res)
}

fn format_response(response: HttpResponse) -> String {
  let status_line = status_str(response.status_code)
  let headers =
    response.headers
    |> list.map(header_str)
    |> string.join("\r\n")

  "HTTP/1.1 " <> status_line <> "\r\n" <> headers <> "\r\n" <> response.body
}

fn status_str(code: HttpStatus) -> String {
  case code {
    Success -> "200 OK"
  }
}

fn header_str(header: HttpHeader) -> String {
  let HttpHeader(key, val) = header
  key <> ": " <> val
}
