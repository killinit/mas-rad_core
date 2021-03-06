class InvestmentSize < ActiveRecord::Base
  include Translatable
  include FriendlyNamable

  has_and_belongs_to_many :firms

  validates_presence_of :name

  default_scope { order(:order) }
end
