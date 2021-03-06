RSpec.describe Adviser do
  describe '#geocoded?' do
    context 'when the adviser has lat/long' do
      it 'is classed as geocoded' do
        expect(build(:adviser)).to be_geocoded
      end
    end

    context 'when the adviser does not have lat/long' do
      it 'is not classed as geocoded' do
        expect(build(:adviser, latitude: nil, longitude: nil)).to_not be_geocoded
      end
    end
  end

  describe 'before validation' do
    context 'when a reference number is present' do
      let(:attributes) { attributes_for(:adviser) }
      let(:adviser) { Adviser.new(attributes) }

      before do
        Lookup::Adviser.create!(
          reference_number: attributes[:reference_number],
          name: 'Mr. Welp'
        )
      end

      it 'assigns #name from the lookup Adviser data' do
        adviser.validate

        expect(adviser.name).to eq('Mr. Welp')
      end
    end
  end

  describe 'validation' do
    it 'is valid with valid attributes' do
      expect(build(:adviser)).to be_valid
    end

    it 'orders fields correctly for dough' do
      expect(build(:adviser).field_order).not_to be_empty
    end

    describe 'geographical coverage' do
      describe 'travel distance' do
        it 'must be provided' do
          expect(build(:adviser, travel_distance: nil)).to_not be_valid
        end

        it 'must be within the allowed options' do
          expect(build(:adviser, travel_distance: 999)).to_not be_valid
        end
      end

      describe 'postcode' do
        it 'must be provided' do
          expect(build(:adviser, postcode: nil)).to_not be_valid
        end

        it 'must be a valid format' do
          expect(build(:adviser, postcode: 'Z')).to_not be_valid
        end
      end
    end

    describe 'statement of truth' do
      it 'must be confirmed' do
        expect(build(:adviser, confirmed_disclaimer: false)).to_not be_valid
      end
    end

    describe 'reference number' do
      it 'is required' do
        expect(build(:adviser, reference_number: nil)).to_not be_valid
      end

      it 'must be three characters and five digits exactly' do
        %w(badtimes ABCDEFGH 8008135! 12345678).each do |bad|
          Lookup::Adviser.create!(reference_number: bad, name: 'Mr. Derp')

          expect(build(:adviser,
                       reference_number: bad,
                       create_linked_lookup_advisor: false)).to_not be_valid
        end
      end

      it 'must be matched to the lookup data' do
        build(:adviser, reference_number: 'ABC12345').tap do |a|
          Lookup::Adviser.delete_all

          expect(a).to_not be_valid
        end
      end

      context 'when an adviser with the same reference number already exists' do
        let(:reference_number) { 'ABC12345' }

        before do
          create(:adviser, reference_number: reference_number)
        end

        it 'must not be valid' do
          expect(build(:adviser,
                       reference_number: reference_number,
                       create_linked_lookup_advisor: false)).to_not be_valid
        end
      end
    end
  end

  describe '#full_street_address' do
    let(:adviser) { create(:adviser) }
    subject { adviser.full_street_address }

    it { is_expected.to eql "#{adviser.postcode}, United Kingdom"}
  end

  it_should_behave_like 'geocodable' do
    subject(:adviser) { create(:adviser) }
    let(:job_class) { GeocodeAdviserJob }
  end

  describe 'after_commit :geocode' do
    let(:adviser) { create(:adviser) }

    before do
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    end

    context 'when the postcode is present' do
      it 'the adviser is scheduled for geocoding' do
        expect { adviser.run_callbacks(:commit) }.to change { ActiveJob::Base.queue_adapter.enqueued_jobs }
      end
    end

    context 'when the postcode is not valid' do
      before { adviser.postcode = 'not-valid' }

      it 'the adviser is not scheduled for geocoding' do
        expect { adviser.run_callbacks(:commit) }.not_to change { ActiveJob::Base.queue_adapter.enqueued_jobs }
      end
    end

    context 'when the subject is destroyed' do
      before do
        adviser.destroy
        adviser.run_callbacks(:commit)
      end

      def queue_contains_a_job_for(job_class)
        ActiveJob::Base.queue_adapter.enqueued_jobs.any? do |elem|
          elem[:job] == job_class
        end
      end

      it 'the adviser is not scheduled for geocoding' do
        expect(queue_contains_a_job_for(GeocodeAdviserJob)).to be_falsey
      end

      it 'the adviser\'s firm is scheduled for geocoding/indexing' do
        expect(queue_contains_a_job_for(GeocodeFirmJob)).to be_truthy
      end
    end
  end

  describe 'after_save :flag_changes_for_after_commit' do
    let(:original_firm) { create(:firm) }
    let(:receiving_firm) { create(:firm) }
    subject { create(:adviser, firm: original_firm) }

    before do
      subject.firm = receiving_firm
      subject.save!
    end

    context 'when the firm has changed' do
      it 'stores the original firm id so it can be reindexed in an after_commit hook' do
        expect(subject.old_firm_id).to eq(original_firm.id)
      end
    end
  end

  describe 'after_commit :reindex_old_firm' do
    let(:original_firm) { create(:firm) }
    let(:receiving_firm) { create(:firm) }
    subject { create(:adviser, firm: original_firm) }

    def save_with_commit_callback(model)
      model.save!
      model.run_callbacks(:commit)
    end

    context 'when the firm has changed' do
      it 'triggers reindexing of the adviser and new firm' do
        expect(GeocodeAdviserJob).to receive(:perform_later).with(subject)
        subject.firm = receiving_firm
        save_with_commit_callback(subject)
      end

      it 'triggers reindexing of the original firm (once)' do
        expect(IndexFirmJob).to receive(:perform_later).once().with(original_firm)
        subject.firm = receiving_firm
        save_with_commit_callback(subject)

        # Trigger a second time
        subject.run_callbacks(:commit)
      end
    end
  end

  describe '.move_all_to_firm' do
    let(:original_firm) { create(:firm_with_advisers) }
    let(:receiving_firm) { create(:firm_with_advisers) }

    it 'moves a batch of advisers to another firm' do
      advisers_to_move = original_firm.advisers.limit(2)
      advisers_to_move.move_all_to_firm(receiving_firm)

      expect(advisers_to_move[0].firm).to be(receiving_firm)
      expect(advisers_to_move[1].firm).to be(receiving_firm)

      receiving_firm.reload
      original_firm.reload

      expect(original_firm.advisers.count).to be(1)
      expect(receiving_firm.advisers.count).to be(5)
      expect(receiving_firm.adviser_ids).to include(advisers_to_move[0].id,
                                                    advisers_to_move[1].id)
      expect(original_firm.adviser_ids).not_to include(advisers_to_move[0].id,
                                                       advisers_to_move[1].id)
    end

    context 'when one of the move operations fails' do
      let(:advisers_to_move) { original_firm.advisers.limit(3) }
      let(:invalid_record_index) { 1 }

      before do
        advisers_to_move[invalid_record_index].reference_number = 'NOT_VALID'
        advisers_to_move[invalid_record_index].save!(validate: false)
      end

      it 'aborts the entire operation' do
        expect(advisers_to_move[invalid_record_index]).not_to be_valid
        expect { advisers_to_move.move_all_to_firm(receiving_firm) }
          .to raise_error(ActiveRecord::RecordInvalid)

        receiving_firm.reload
        original_firm.reload

        expect(original_firm.advisers.count).to be(3)
        expect(receiving_firm.advisers.count).to be(3)
      end
    end
  end
end
