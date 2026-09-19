# A clean, dependency-free helper module — the well-graded file in this fixture.
module Util
  # Join the given parts with a separator, defaulting to a comma.
  def self.join(parts, sep = ",")
    parts.join(sep)
  end

  # Sum a list of numbers.
  def self.total(values)
    sum = 0
    values.each do |v|
      sum += v
    end
    sum
  end
end
