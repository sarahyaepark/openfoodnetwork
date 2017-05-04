require 'spec_helper'

describe LineItemsController do
  let(:item) { create(:line_item) }
  let(:user) { create(:user) }
  let(:distributor) { create(:distributor_enterprise) }
  let(:order_cycle) { create(:simple_order_cycle) }
  let(:completed_order) do
    order = create(:completed_order_with_totals, user: user, distributor: distributor, order_cycle: order_cycle)
    while !order.completed? do break unless order.next! end
    order
  end
  let(:item_with_oc) do
    item.order.user = user
    item.order.order_cycle = order_cycle
    item.order.distributor = distributor
    item.order.save
    item
  end

  it "lists items bought by the user from the same shop in the same order_cycle" do
    controller.stub spree_current_user: completed_order.user
    controller.stub current_order_cycle: item_with_oc.order.order_cycle
    controller.stub current_distributor: item_with_oc.order.distributor
    get :index, { format: :json }
    expect(response.status).to eq 200
    json_response = JSON.parse(response.body)
    expect(json_response.length).to eq completed_order.line_items(:reload).count
    expect(json_response[0]['id']).to eq completed_order.line_items.first.id
  end

  it "fails without line item id" do
    expect { delete :destroy }.to raise_error
  end

  it "denies deletion without order cycle" do
    request = { format: :json, id: item }
    delete :destroy, request
    expect(response.status).to eq 403
    expect { item.reload }.to_not raise_error
  end

  it "denies deletion without user" do
    request = { format: :json, id: item_with_oc }
    delete :destroy, request
    expect(response.status).to eq 403
    expect { item.reload }.to_not raise_error
  end

  it "denies deletion if editing is not allowed" do
    controller.stub spree_current_user: item.order.user
    request = { format: :json, id: item_with_oc }
    delete :destroy, request
    expect(response.status).to eq 403
    expect { item.reload }.to_not raise_error
  end

  it "deletes the line item if allowed" do
    controller.stub spree_current_user: item.order.user
    distributor = item_with_oc.order.distributor
    distributor.allow_order_changes = true
    distributor.save
    request = { format: :json, id: item_with_oc }
    delete :destroy, request
    expect(response.status).to eq 204
    expect { item.reload }.to raise_error
  end

  describe "destroying a line item" do
    context "where shipping and payment fees apply" do
      let(:distributor) { create(:distributor_enterprise, charges_sales_tax: true, allow_order_changes: true) }
      let(:shipping_fee) { 3 }
      let(:payment_fee) { 5 }
      let(:order) { create(:completed_order_with_fees, distributor: distributor, shipping_fee: shipping_fee, payment_fee: payment_fee) }

      before do
        Spree::Config.shipment_inc_vat = true
        Spree::Config.shipping_tax_rate = 0.25
      end

      it "updates the fees" do
        # Sanity check fees
        item_num = order.line_items.length
        initial_fees = item_num * (shipping_fee + payment_fee)
        expect(order.adjustment_total).to eq initial_fees
        expect(order.shipment.adjustment.included_tax).to eq 1.2

        # Delete the item
        item = order.line_items.first
        controller.stub spree_current_user: order.user
        request = { format: :json, id: item }
        delete :destroy, request
        expect(response.status).to eq 204

        # Check the fees again
        order.reload
        order.shipment.reload
        expect(order.adjustment_total).to eq initial_fees - shipping_fee - payment_fee
        expect(order.shipment.adjustment.amount).to eq shipping_fee
        expect(order.payment.adjustment.amount).to eq payment_fee
        expect(order.shipment.adjustment.included_tax).to eq 0.6
      end
    end

    context "where enterprise fees apply" do
      let(:user) { create(:user) }
      let(:variant) { create(:variant) }
      let(:distributor) { create(:distributor_enterprise, allow_order_changes: true) }
      let(:order_cycle) { create(:simple_order_cycle, distributors: [distributor]) }
      let(:enterprise_fee) { create(:enterprise_fee, calculator: Spree::Calculator::PerItem.new ) }
      let!(:exchange) { create(:exchange, sender: variant.product.supplier, receiver: order_cycle.coordinator, variants: [variant], enterprise_fees: [enterprise_fee]) }
      let!(:order) do
        order = create(:order, distributor: distributor, order_cycle: order_cycle, user: user)
        order.line_items << build(:line_item, variant: variant)
        order.update_distribution_charge!
        order.save!
        order
      end
      let(:params) { { format: :json, id: order.line_items.first } }

      it "updates the fees" do
        expect(order.adjustment_total).to eq enterprise_fee.calculator.preferred_amount

        controller.stub spree_current_user: user
        delete :destroy, params
        expect(response.status).to eq 204

        expect(order.reload.adjustment_total).to eq 0
      end
    end
  end
end
