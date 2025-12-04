defmodule DoctransWeb.PageController do
  use DoctransWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
