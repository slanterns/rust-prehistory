// -*- C++ -*-

fn child() -> () {
  check (1 == 2);
}

fn main() -> () {
  let port[int] p = port();
  spawn child();
  let int x;
  x <- p;
}