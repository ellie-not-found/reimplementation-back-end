require 'rails_helper'

RSpec.describe ResponsesController, type: :controller do

  let(:response) { Response.new(map_id: 1, response_map: review_response_map, scores: [answer]) }

  describe 'DELETE #delete' do
    context 'when response exists' do
      it 'return status success' do
        @response = :response
        allow(@response).to receive(:delete)
        result = ResponsesController.delete

        expect(result.status).to eq(:deleted)
      end
    end
  end
end