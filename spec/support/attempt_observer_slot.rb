# frozen_string_literal: true

# The attempt seam's one observer slot, emptied for an example that installs
# its own (as a host that loads no evals has it), and given back what it
# held after: Smith::Evals::Recording, once any spec has loaded smith/evals.
module AttemptObserverSlot
  def self.emptied
    held = Smith::AttemptObservation.observer
    Smith::AttemptObservation.uninstall(held) if held
    yield
  ensure
    current = Smith::AttemptObservation.observer
    Smith::AttemptObservation.uninstall(current) if current
    Smith::AttemptObservation.install(held) if held
  end
end
