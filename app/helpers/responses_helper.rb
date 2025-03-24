module ResponsesHelper
    def questionnaire_from_response_map(map, contributor, assignment)
        if ['ReviewResponseMap', 'SelfReviewResponseMap'].include?(map.type)
            get_questionnaire_by_contributor(map, contributor, assignment)
        else
            get_questionnaire_by_duty(map, assignment)
        end
    end
    def get_questionnaire_by_contributor(map, contributor, assignment)
        
        reviewees_topic = SignedUpTeam.find_by(team_id: contributor.id)&.sign_up_topic_id
        current_round = DueDate.next_due_date(reviewees_topic).round
        map.questionnaire(current_round, reviewees_topic)
    end
    def get_questionnaire_by_duty(map, assignment)
        if assignment.duty_based_assignment?
            # E2147 : gets questionnaire of a particular duty in that assignment rather than generic questionnaire
            map.questionnaire_by_duty(map.reviewee.duty_id)
        else
            map.questionnaire
        end
    end

    #Combine functionality of set_content and assign_action_parameters
    def prepare_response_content(map, action_params = nil, new_response = false)
        # Set title and other initial content based on the map

        title = map.get_title
        survey_parent = nil
        assignment = nil
        participant = map.reviewer
        contributor = map.contributor
  
        if map.survey?
          survey_parent = map.survey_parent
        else
          assignment = map.assignment
        end
  
        # Get the questionnaire and sort questions
        questionnaire = questionnaire_from_response_map(map, contributor, assignment)
        review_questions = Response.sort_by_version(questionnaire.questions)
        min = questionnaire.min_question_score
        max = questionnaire.max_question_score

        # Initialize response if new_response is true
        response = nil
        if new_response
          response = Response.where(map_id: map.id).order(updated_at: :desc).first
          if response.nil?
            response = Response.create(map_id: map.id, additional_comment: '', is_submitted: 0)
          end
        end
  

  
        # Set up dropdowns or scales
        set_dropdown_or_scale(questionnaire, assignment)
  
        # Process the action parameters if provided
        if action_params
          case action_params[:action]
          when 'edit'
            header = 'Edit'
            next_action = 'update'
            response = Response.find(action_params[:id])
            contributor = map.contributor
          when 'new'
            header = 'New'
            next_action = 'create'
            feedback = action_params[:feedback]
            modified_object = map.id
          end
        end

        
        # Return the data as a hash
        {
          title: title,
          survey_parent: survey_parent,
          assignment: assignment,
          participant: participant,
          contributor: contributor,
          response: response,
          review_questions: review_questions,
          min: min,
          max: max,
          header: header || 'Default Header',
          next_action: next_action || 'create',
          feedback: feedback,
          map: map,
          modified_object: modified_object,
          return: action_params ? action_params[:return] : nil
        }
    end
  
    def set_dropdown_or_scale(assignment, questionaire)
          @dropdown_or_scale = if AssignmentQuestionnaire.exists?(assignment_id: @assignment.try(:id), 
                                                                   questionnaire_id: @questionnaire.try(:id), 
                                                                   dropdown: true)
                                  'dropdown'
                              else
                                  'scale'
                              end
    end

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
        response_edit_allowed?(response.map, user_id)
      end
    end

    #Renamed to sort_items from sort_questions
    def sort_items(questions)
      questions.sort_by(&:seq)
    end

    def current_user_is_reviewer?(map, _reviewer_id)
      map.reviewer.current_user_is_reviewer?(current_user&.id)
    end

    def create_answers(params, questions)
      params[:responses].each do |key, value|
        question_id = questions[key.to_i].id
        answer = Answer.find_or_initialize_by(response_id: @response.id, question_id: question_id)
        
        answer.update(answer: value[:score], comments: value[:comment])
      end
    end

    def init_answers(response, questions)
      questions.each do |q|
        # it's unlikely that these answers exist, but in case the user refresh the browser some might have been inserted.
        answer = Answer.where(response_id: response.id, question_id: q.id).first
        if answer.nil?
          Answer.create(response_id: response.id, question_id: q.id, answer: nil, comments: '')
        end
      end
    end
  
  # Assigns total contribution for cake question across all reviewers to a hash map
  # Key : question_id, Value : total score for cake question
  def total_cake_score(response)
    reviewee = ResponseMap.select(:reviewee_id, :type).where(id: response.map_id).first
    return Cake.get_total_score_for_questions(reviewee.type,
                                                      @review_questions,
                                                      @participant.id,
                                                      @assignment.id,
                                                      reviewee.reviewee_id)
  end

  def find_or_create_feedback
    map = FeedbackResponseMap.where(reviewed_object_id: @response.id, reviewer_id: @participant.id).first
    if map.nil?
      map = FeedbackresponseMap.create(reviewed_object_id: @response.id, reviewer_id: @participant.id, reviewee_id: @response.map.reviewer.id)
    end
    map
  end
    
    # This method is called within set_content when the new_response flag is set to False
  # This method gets the questionnaire directly from the response object since it is available.
  def questionnaire_from_response
    # if user is not filling a new rubric, the @response object should be available.
    # we can find the questionnaire from the question_id in answers
    answer = @response.scores.first
    @questionnaire = @response.questionnaire_by_answer(answer)
  end
end