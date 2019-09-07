defmodule Delega.Slack.Interactive do
  @moduledoc """
  Logic for interacting with Slack.
  """

  alias Delega.Slack.Renderer
  alias Delega.{Repo, Team, Todo}

  def send_complete_msg(
        to_user_id,
        todo = %{completed_user_id: completed_user_id, todo: todo_msg},
        access_token
      ) do
    Slack.API.post_message(%{
      token: access_token,
      channel: to_user_id,
      text: "#{Renderer.escape_user_id(completed_user_id)} completed #{todo_msg}",
      blocks: Renderer.render_todo(todo)
    })
  end

  def send_reject_msg(
        to_user_id,
        deleted_user_id,
        todo,
        access_token
      ) do
    Slack.API.post_message(%{
      token: access_token,
      channel: to_user_id,
      text: "#{Renderer.escape_user_id(deleted_user_id)} rejected #{todo.todo}",
      blocks: Renderer.render_todo(todo)
    })
  end

  def send_bulk_complete_msg(todo, access_token) do
    MapSet.new([todo.completed_user_id, todo.created_user_id, todo.assigned_user_id])
    |> MapSet.delete(todo.completed_user_id)
    |> Enum.map(&Task.start(fn -> send_complete_msg(&1, todo, access_token) end))
  end

  def send_bulk_reject_msg(todo, rejected_user_id, access_token) do
    MapSet.new([rejected_user_id, todo.created_user_id, todo.assigned_user_id])
    |> MapSet.delete(rejected_user_id)
    |> Enum.map(
      &Task.start(fn ->
        send_reject_msg(&1, rejected_user_id, todo, access_token)
      end)
    )
  end

  def notify_channels(todo, access_token, text, blocks) do
    todo
    |> Ecto.assoc(:channels)
    |> Repo.all()
    |> Enum.map(&Map.get(&1, :channel_id))
    |> Enum.map(fn channel_id ->
      Task.start(fn ->
        Slack.API.post_message(%{
          token: access_token,
          text: text,
          channel: channel_id,
          blocks: blocks
        })
      end)
    end)
  end

  def send_welcome_msg(user_id, access_token) do
    Slack.API.post_message(%{
      token: access_token,
      channel: user_id,
      blocks: Renderer.render_welcome_msg(),
      text: "Welcome to Delega!"
    })
  end

  def parse_action(action_token) do
    list = action_token |> String.split(":")

    %{
      context: list |> Enum.at(0),
      action: list |> Enum.at(1),
      todo_id: list |> Enum.at(2) |> String.to_integer()
    }
  end

  def do_action("complete", todo, completed_user_id, access_token) do
    if todo.status != "COMPLETE" do
      todo = todo |> Todo.complete!(completed_user_id)

      todo = Todo.get_with_assoc(todo.todo_id)

      send_bulk_complete_msg(todo, access_token)

      notify_channels(
        todo,
        access_token,
        "#{Renderer.escape_user_id(completed_user_id)} completed #{todo.todo}",
        Renderer.render_todo(todo)
      )

      Renderer.render_todo(todo)
    else
      Renderer.render_todo(todo)
    end
  end

  def do_action("reject", todo, rejected_user_id, access_token) do
    if todo.status != "COMPLETE" do
      todo =
        todo
        |> Todo.reject!(rejected_user_id)

      todo = Todo.get_with_assoc(todo.todo_id)

      send_bulk_reject_msg(todo, rejected_user_id, access_token)

      notify_channels(
        todo,
        access_token,
        "#{Renderer.escape_user_id(rejected_user_id)} rejected #{todo.todo}",
        Renderer.render_todo(todo)
      )

      Renderer.render_todo(todo)
    else
      Renderer.render_todo(todo)
    end
  end

  def send_todo_reminder(access_token, user_id) do
    todos = Todo.get_todo_list(user_id)

    if length(todos) > 0 do
      blocks = Renderer.render_todo_reminder(todos)

      Slack.API.post_message(%{
        token: access_token,
        channel: user_id,
        blocks: blocks,
        text: "Here are your todos for today"
      })
    end
  end

  def dispatch_action(action_token, action_user_id, team_id, response_url) do
    %{context: context, todo_id: todo_id, action: action} = parse_action(action_token)

    %{access_token: access_token} = Team |> Repo.get!(team_id)
    todo = Todo.get_with_assoc(todo_id)

    action_blocks = do_action(action, todo, action_user_id, access_token)

    context_blocks =
      case context do
        "todo_list" -> Renderer.render_todo_list(action_user_id)
        "delegation_list" -> Renderer.render_delegation_list(action_user_id)
        _ -> []
      end

    blocks = (context_blocks ++ action_blocks) |> List.flatten()

    # Send response to Slack
    Task.start(fn ->
      HTTPoison.post!(
        response_url,
        Jason.encode!(%{
          "response_type" => "ephemeral",
          "blocks" => blocks
        }),
        [{"Content-type", "application/json"}]
      )
    end)
  end
end
