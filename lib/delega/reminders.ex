defmodule Delega.Reminders do
  use GenServer

  alias Delega.{Repo, Todo, User}

  import Ecto.Query, only: [from: 2]

  def start_link do
    GenServer.start_link(__MODULE__, %{}, name: Delega.Reminders)
  end

  def init(state) do
    Process.send_after(self(), :hourly_reminders, ms_until_reminder(Time.utc_now()))

    {:ok, state}
  end

  def handle_info(:hourly_reminders, state) do
    Process.send_after(self(), :hourly_reminders, ms_until_reminder(Time.utc_now()))
    send_reminders(9, 0)
    {:noreply, state}
  end

  def ms_until_reminder(now) do
    one_hour = 60 * 60 * 1000
    {microseconds, _} = now.microsecond
    milliseconds = round(microseconds / 1000)

    one_hour - now.minute * 60 * 1000 - now.second * 1000 - milliseconds
  end

  def reminder?(now, reminder_time, tz_offset, tolerance) do
    now_tz = DateTime.add(now, tz_offset)

    case Date.day_of_week(now_tz) do
      6 ->
        false

      7 ->
        false

      _ ->
        now_tz = DateTime.to_time(now_tz)
        diff = Time.diff(now_tz, reminder_time)

        diff < tolerance and diff >= 0
    end
  end

  def send_reminders(reminder_hour, reminder_minute) do
    now = DateTime.utc_now()
    {:ok, reminder_time} = Time.new(reminder_hour, reminder_minute, 0, 0)

    from(user in User,
      distinct: true,
      join: todo in Todo,
      on: todo.assigned_user_id == user.user_id,
      where: todo.status == "NEW",
      preload: [:team]
    )
    |> Repo.all()
    |> Enum.map(fn user ->
      if reminder?(now, reminder_time, user.tz_offset, 60 * 59) do
        Task.start(fn ->
          Delega.Slack.Interactive.send_todo_reminder(user.team, user)
        end)
      end
    end)
  end
end
