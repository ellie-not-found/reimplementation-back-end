class Api::V1::ResponsesController < ApplicationController
  include ResponsesHelper
  include ScorableHelper
  before_action :set_response, only: %i[ show update destroy ]
  skip_before_action :authorize

  def action_allowed?
    return !current_user.nil? unless %w[edit delete update view].include?(params[:action])
  
    response = Response.find(params[:id])
    user_id = response.map.reviewer&.user_id
  
    case params[:action]
    when 'edit'
      return false if response.is_submitted
      current_user_is_reviewer?(response.map, user_id)
    when 'delete', 'update'
      current_user_is_reviewer?(response.map, user_id)
    when 'view'
      response_edit_allowed?(response.map, user_id, response)
    end
  end

  

  # GET /api/v1/responses
  def index
    @responses = Response.all

    render json: @responses
  end

  # GET /api/v1/responses/1
  def show
    if @response
      render json: @response, status: :ok
    else
      render json: { error: 'Response not found' }, status: :not_found
    end
  end

  def new
    @map = ResponseMap.find(params[:id])
    attributes = prepare_response_content(@map, 'New', true)
    attributes.each do |key, value|
      instance_variable_set("@#{key}", value)
    end
    questions = sort_items(@questionnaire.items)
    @total_score = total_cake_score(@response)
    init_answers(@response, questions)
    render action: 'response'
  end

  # POST /api/v1/responses
  def create
    @map = find_map
    @questionnaire = find_questionnaire
    is_submitted = (params[:isSubmit] == 'Yes')

    @response = find_or_create_response(is_submitted)
    was_submitted = @response.is_submitted

    if @response.save
      update_response(is_submitted)
      process_items if params[:responses]
      notify_instructor_if_needed(was_submitted)
      msg = 'Your response was successfully saved'
      error_msg = ''
      redirect_to controller: 'responses', action: 'save', id: @map.map_id,
              return: params.permit(:return)[:return], msg: msg, review: params.permit(:review)[:review],
              save_options: params.permit(:save_options)[:save_options]
    else
      render json: @response.errors, status: :unprocessable_entity
    end
  end

  def edit 
    action_params = { action: 'edit', id: params[:id], return: params[:return] }
    response_content = prepare_response_content(@map, action_params)
  
    # Assign variables from response_content hash
    response_content.each { |key, value| instance_variable_set("@#{key}", value) }

    @largest_version_num  = Response.sort_by_version(@review_questions)
    @review_scores = @review_questions.map do |question|
      Answer.where(response_id: @response.response_id, question_id: question.id).first
    end
  end

  # PATCH/PUT /api/v1/responses/1
  def update
    return render nothing: true unless action_allowed?

    @response.update_attribute('additional_comment', params[:review][:comments])
    @questionnaire = @response.questionnaire_by_answer(@response.scores.first)
    
    questions = sort_items(@questionnaire.questions)

    # for some rubrics, there might be no questions but only file submission (Dr. Ayala's rubric)
    create_answers(params, questions) unless params[:responses].nil?
    if params['isSubmit'] && params['isSubmit'] == 'Yes'
      @response.update_attribute('is_submitted', true)
    end

    # Add back emailing logic
    if (@map.is_a? ReviewResponseMap) && @response.is_submitted && @response.significant_difference?
      @response.send_score_difference_email
    end

    redirect_to_response_update
  end

  def delete
    if @response.delete
      render json: @response, status: :deleted, location: @response
    else
      render json: @response.errors, status: :unprocessable_entity
    end
  end

  # DELETE /api/v1/responses/1
  def destroy
    @response.destroy!
  end

  def save
    @map = ResponseMap.find(params[:id])
    @return = params[:return]
    @map.save
    msg = 'Your response was successfully saved'
    error_msg = ''
    redirect_to controller: 'responses', action: 'save', id: @map.map_id,
            return: params.permit(:return)[:return], msg: msg, review: params.permit(:review)[:review],
            save_options: params.permit(:save_options)[:save_options]
  end
  
  def new_feedback
    if Response.find(params[:id])
      @map = Response.find(params[:id]).map
      response_content = prepare_response_content(@map)

      # Assign variables from response_content hash
      response_content.each { |key, value| instance_variable_set("@#{key}", value) }
      if @response
        @reviewer = AssignmentParticipant.where(user_id: current_user.id, parent_id: @response.map.assignment.id).first
        map = find_or_create_feedback
        redirect_to action: 'new', id: map.id, return: 'feedback'
      end
    else
      redirect_back fallback_location: root_path
    end
  end
  
  # toggle_permission allows user update visibility.
  def toggle_permission
    return head :no_content unless action_allowed?

    error = update_visibility(params[:visibility])
    if error == ''
      map_id = @response.map.map_id
    else
      map_id = nil
    end
    redirect_to action: 'redirect', id: map_id, return: params[:return], msg: params[:msg], error_msg: error
  end

  def show_calibration_results_for_student
    @assignment = Assignment.find(params[:assignment_id])
    @calibration_response = ReviewResponseMap.find(params[:calibration_response_map_id]).response[0]
    @review_response = ReviewResponseMap.find(params[:review_response_map_id]).response[0]
    @review_questions = AssignmentQuestionnaire.get_questions_by_assignment_id(params[:assignment_id])
  end

  def authorize_show_calibration_results
    response_map = ResponseMap.find(params[:review_response_map_id])
    user_id = response_map.reviewer.user_id if response_map.reviewer
    # Deny access to the calibration result page if the current user is not a reviewer.
    unless current_user_is_reviewer?(response_map, user_id)
      flash[:error] = 'You are not allowed to view this calibration result'
      redirect_to controller: 'student_review', action: 'list', id: user_id
    end
  end

  #This method was not updated
  def redirect
    error_id = params[:error_msg]
    message_id = params[:msg]
    flash[:error] = error_id unless error_id&.empty?
    flash[:note] = message_id unless message_id&.empty?
    @map = Response.find_by(map_id: params[:id])
    case params[:return]
    when 'feedback'
      redirect_to controller: 'grades', action: 'view_my_scores', id: @map.reviewer.id
    when 'teammate'
      redirect_to view_student_teams_path student_id: @map.reviewer.id
    when 'instructor'
      redirect_to controller: 'grades', action: 'view', id: @map.response_map.assignment.id
    when 'assignment_edit'
      redirect_to controller: 'assignments', action: 'edit', id: @map.response_map.assignment.id
    when 'selfreview'
      redirect_to controller: 'submitted_content', action: 'edit', id: @map.response_map.reviewer_id
    when 'survey'
      redirect_to controller: 'survey_deployment', action: 'pending_surveys'
    when 'bookmark'
      bookmark = Bookmark.find(@map.response_map.reviewee_id)
      redirect_to controller: 'bookmarks', action: 'list', id: bookmark.topic_id
    when 'ta_review' # Page should be directed to list_submissions if TA/instructor performs the review
      redirect_to controller: 'assignments', action: 'list_submissions', id: @map.response_map.assignment.id
    else
      # if reviewer is team, then we have to get the id of the participant from the team
      # the id in reviewer_id is of an AssignmentTeam
      reviewer_id = @map.response_map.reviewer.get_logged_in_reviewer_id(current_user.try(:id))
      redirect_to controller: 'student_review', action: 'list', id: reviewer_id
    end
  end


  private

  def find_map
    map_id = params[:map_id] || params[:id]

    ResponseMap.find_by(id: map_id)
  end

  def find_questionnaire
    if params[:review][:questionnaire_id]
      questionnaire = Questionnaire.find(params[:review][:questionnaire_id])
    else
      questionnaire = nil
    end
    questionnaire
  end

  def find_response
    @review = Response.find(params[:id]) unless params[:id].nil?
  end

  # Only allow a list of trusted parameters through.
  def response_params
    params.fetch(:response, {})
  end

  def find_or_create_response(is_submitted = false)
    response = Response.where(map_id: @map.map_id).order(created_at: :desc).first
    if response.nil?
      response = Response.create(map_id: @map.id, additional_comment: params[:review][:comments],
                                 is_submitted: is_submitted)
    end
    response
  end

  def update_response(is_submitted)
    @response.update(additional_comment: params[:review][:comments], is_submitted: is_submitted)
  end

  def process_items
    items = sort_items(@questionnaire.items)
    items = @questionnaire.items
    create_answers(params, items)
  end

  def notify_instructor_if_needed(was_submitted)
    if @map.is_a?(ReviewResponseMap) && !was_submitted && @response.is_submitted && @response.significant_difference?
      @response.notify_instructor_on_difference
      @response.email
    end
  end

  def redirect_to_response_update
    msg = 'Your response was successfully updated'
    error_msg = ''
    redirect_to controller: 'responses', action: 'save', id: @map.map_id,
              return: params.permit(:return)[:return], msg: msg, review: params.permit(:review)[:review],
              save_options: params.permit(:save_options)[:save_options]
  end

  # Use callbacks to share common setup or constraints between actions.
  def set_response
    @response = Response.find(params[:id])
  end

  # Only allow a list of trusted parameters through.
  def response_params
    params.require(:response).permit(
      :isSubmit,
      :map_id,
      :id,
      review: [:comments, :questionnaire_id],
      responses: {}, # Adjust based on structure
      save_options: {},
      return: {}
    )
  end
end
