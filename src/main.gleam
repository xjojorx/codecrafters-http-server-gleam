import gleam/io

// Uncomment this block to pass the first stage
//
// import gleam/erlang/process
// import gleam/option.{None}
// import gleam/otp/actor
// import glisten

pub fn main() {
  // You can use print statements as follows for debugging, they'll be visible when running tests.
  io.println("Logs from your program will appear here!")

  // Uncomment this block to pass the first stage
  //
  // let assert Ok(_) =
  //   glisten.handler(fn(_conn) { #(Nil, None) }, fn(_msg, state, _conn) {
  //     io.println("Received message!")
  //     actor.continue(state)
  //   })
  //   |> glisten.serve(4221)
  //
  // process.sleep_forever()
}
