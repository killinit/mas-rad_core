class AdviserSerializer < ActiveModel::Serializer
  self.root = false

  attributes :_id, :name, :range, :location, :range_location

  def _id
    object.id
  end

  def range
    object.travel_distance
  end

  def location
    {
      lat: object.latitude,
      lon: object.longitude
    }
  end

  def range_location
    {
      type: :circle,
      coordinates: [object.longitude, object.latitude],
      radius: "#{object.travel_distance}miles"
    }
  end
end
