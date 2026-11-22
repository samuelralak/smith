# frozen_string_literal: true

# A nested workflow fanned out over items (0.16.0).
module CoreInvisibility
  # 20. One nested run an item, at most two at once, each item's outcome in
  # order.
  D.agent("GoldenRoomAgent", :golden_room, prompt: "Describe the room.")
  D.workflow("GoldenRoomWorkflow") do
    initial_state :idle
    seed_messages { |context| [{ role: :user, content: "Describe #{context[:room]}." }] }
    transition :describe, from: :idle, to: :done do
      execute :golden_room
    end
  end
  D.workflow("GoldenRoomsWorkflow") do
    initial_state :idle
    state :failed
    transition :describe, from: :idle, to: :described do
      workflow GoldenRoomWorkflow, over: ->(context) { context[:rooms] }, item_to: :room, concurrency: 2,
                                   output_to: :descriptions
      on_failure :fail
    end
  end
  scenario(:nested_items, concurrent: true) do |run|
    run.server.answer { D.by_request(_1) }
    persisted(run, GoldenRoomsWorkflow, "run-rooms", context: { rooms: ["the kitchen", "the hall", "the porch"] })
  end
end
