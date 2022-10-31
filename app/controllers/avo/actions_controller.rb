require_dependency "avo/application_controller"

module Avo
  class ActionsController < ApplicationController
    before_action :set_resource_name
    before_action :set_resource
    before_action :set_model, only: :show, if: ->(request) do
      # Try to se the model only if the user is on the record page.
      # set_model will fail if it's tried to be used from the Index page.
      request.params[:id].present?
    end
    before_action :set_action, only: [:show, :handle]

    def show
      # Se the view to :new so the default value gets prefilled
      @view = :new

      @resource.hydrate(model: @model, view: @view, user: _current_user, params: params)
      @model = ActionModel.new @action.get_attributes_for_action
    end

    def handle
      resource_ids = action_params[:fields][:avo_resource_ids].split(",")
      @selected_query = action_params[:fields][:avo_selected_query]

      fields = action_params[:fields].except(:avo_resource_ids, :avo_selected_query)

      args = {
        fields: fields,
        current_user: _current_user,
        resource: resource
      }

      unless @action.standalone
        args[:models] = if @selected_query.present?
          @resource.model_class.find_by_sql decrypted_query
        else
          @resource.class.find_scope.find resource_ids
        end
      end

      performed_action = @action.handle_action(**args)

      respond performed_action.response
    end

    private

    def action_params
      params.permit(:authenticity_token, :resource_name, :action_id, fields: {})
    end

    def set_action
      @action = action_class.new(model: @model, resource: @resource, user: _current_user, view: @view)
    end

    def action_class
      klass_name = params[:action_id].gsub("avo_actions_", "").camelize

      Avo::BaseAction.descendants.find do |action|
        action.to_s == klass_name
      end
    end

    def respond(response)
      response[:type] ||= :reload
      messages = get_messages response

      if response[:type] == :download
        return send_data response[:path], filename: response[:filename]
      end

      keep_modal_open = messages.select {|message| message[:type] == :keep_modal_open }.first

      if keep_modal_open
        @view = :new
        @model = ActionModel.new get_attributes_from_params

        respond_to do |format|
          format.html do
            flash.now[:error] = keep_modal_open[:body]
            render :show, status: :unprocessable_entity
          end
        end
      else
        respond_to do |format|
          format.html do
            # Flash the messages collected from the action
            messages.each do |message|
              flash[message[:type]] = message[:body]
            end

            if response[:type] == :redirect
              path = response[:path]

              if path.respond_to? :call
                path = instance_eval(&path)
              end

              redirect_to path
            elsif response[:type] == :reload
              redirect_back fallback_location: resources_path(resource: @resource)
            end
          end
        end
      end
    end

    private

    def get_messages(response)
      default_message = {
        type: :info,
        body: I18n.t("avo.action_ran_successfully")
      }

      return [default_message] if response[:messages].blank?

      response[:messages].select do |message|
        # Remove the silent placeholder messages
        message[:type] != :silent
      end
    end

    def decrypted_query
      Avo::Services::EncryptionService.decrypt(
        message: @selected_query,
        purpose: :select_all
      )
    end

    def get_attributes_from_params
      params[:fields].permit(permited_fields).to_h
    end

    def permited_fields
      params[:fields].keys.reject { |key| fields_to_ignore.include? key }
    end

    def fields_to_ignore
      %w[avo_resource_ids, avo_selected_query]
    end
  end
end
