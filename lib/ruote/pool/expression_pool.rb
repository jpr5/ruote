#--
# Copyright (c) 2005-2009, John Mettraux, jmettraux@gmail.com
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
# Made in Japan.
#++

require 'ruote/fei'
require 'ruote/exp/raw'
require 'ruote/engine/context'
require 'ruote/queue/subscriber'


module Ruote

  #
  # A kind of hub for expression activity (apply/reply and launch + cancel).
  #
  class ExpressionPool

    include EngineContext
    include Subscriber

    # Making sure to observe the work queue once the context is known
    #
    def context= (c)

      @context = c
      subscribe(:expressions)
      subscribe(:processes)
    end

    def reply (workitem)

      wqueue.emit(:expressions, :reply, :workitem => workitem)
    end

    # Cancels an expression (removes it and calls its #cancel method).
    #
    # If remove is set to false, the expression will not be removed (ie
    # not be removed from the expression storage). This is used by the
    # on_error handling, where the expression gets overriden anyway.
    #
    def cancel_expression (fei)

      wqueue.emit(:expressions, :cancel, :fei => fei)
    end

    # Immediately 'forgets' the expression (if still present).
    # This sets the expression's @parent_id to nil
    #
    # Returns true if the expression was found and forgotten.
    #
    def forget_expression (fei)

      if exp = expstorage[fei]
        exp.forget
        true
      else
        false
      end
    end

    # This method is called by expressions when applying one of the child
    # expressions.
    #
    def apply_child (exp, child_index, workitem, forget)

      fei = exp.fei.new_child_fei(child_index)

      exp.register_child(fei) unless forget

      wqueue.emit(
        :expressions, :apply,
        :tree => exp.tree.last[child_index],
        :fei => fei,
        :parent_id => forget ? nil : exp.fei,
        :workitem => workitem,
        :variables => forget ? exp.compile_variables : nil)
    end

    # Called by expressions when replying to their parent expression.
    #
    def reply_to_parent (exp, workitem)

      exp.unpersist

      workitem.fei = exp.fei

      if exp.parent_id

        wqueue.emit(
          :expressions, :reply,
          :fei => exp.parent_id, :workitem => workitem)

      else

        wqueue.emit(
          :processes, exp.in_cancel ? :cancelled : :terminated,
          :wfid => exp.fei.wfid, :workitem => workitem)

        # NOTE : a process can terminate multiple times ...
      end
    end

    # Called by the subprocess expression when launching a subprocess instance.
    #
    def launch_sub (pos, tree, parent, workitem, forget=false)

      i = parent.fei.dup
      i.wfid = "#{i.parent_wfid}_#{get_next_sub_id(parent)}"
      i.expid = pos

      parent.register_child(i) unless forget

      wqueue.emit(:processes, :launch_sub, :fei => i)

      wqueue.emit(
        :expressions, :apply,
        :tree => tree,
        :fei => i,
        :parent_id => forget ? nil : parent.fei,
        :workitem => workitem,
        :variables => forget ? parent.compile_variables : {})
    end

    protected

    # Returns a temporary expression, complete with #lookup_variable and
    # #lookup_on.
    # For internal use only.
    #
    def temp_exp (parent_id, variables, workitem, tree=[ 'nada', {}, [] ])

      FlowExpression.new(@context, nil, parent_id, tree, variables, workitem)
    end

    # Applying a branch (creating an expression for it and applying it).
    #
    def apply (eargs)

      tree = eargs[:tree]
      fei = eargs[:fei]
      parent_id = eargs[:parent_id]
      workitem = eargs[:workitem]
      variables = eargs[:variables]

      # NOTE : orphaning will copy vars so parent == nil is OK.

      exp_name = tree.first

      sub = temp_exp(
        parent_id, variables, workitem, tree
      ).lookup_variable(exp_name)

      part = plist.lookup(exp_name)

      if sub or part

        # don't bother passing the looked up value

        tree = [
          part ? 'participant' : 'subprocess',
          tree[1].merge('ref' => exp_name),
          []
        ]

        exp_name = tree.first
      end

      exp_class = expmap.expression_class(exp_name)

      raise "unknown expression '#{exp_name}'" if not exp_class

      workitem.fei = fei
      exp = exp_class.new(@context, fei, parent_id, tree, variables, workitem)

      exp.persist
      wqueue.emit(:expressions, :apply, :fei => exp.fei)

      fei
    end

    # Returns the next available sub id for the given expression.
    #
    def get_next_sub_id (parent)

      prefix, last_sub_id = parent.lookup_variable('/__next_sub_id__')

      prefix ||= ''
      last_sub_id ||= -1

      last_sub_id = last_sub_id + 1

      parent.set_variable('/__next_sub_id__', [ prefix, last_sub_id ])

      "#{prefix}#{last_sub_id}"
    end

    EXP_MESSAGES = %w[ apply reply cancel ].collect { |m| m.to_sym }
    #PROCESS_MESSAGES = %w[ launch cancel ].collect { |m| m.to_sym }

    # Reacting upon :expressions and :processes events.
    #
    def receive (eclass, emsg, eargs)

      if eclass == :expressions

        expressions_receive(emsg, eargs) if EXP_MESSAGES.include?(emsg)

      elsif eclass == :processes

        self.send(emsg, eargs) if emsg == :launch || emsg == :cancel

      end
    end

    def extract_info (emsg, eargs)

      wi = eargs[:workitem]
      fei = eargs[:fei] || wi.fei
      exp = expstorage[fei]

      [ wi, fei, exp ]
    end

    # Calling apply/reply/cancel on an expression (called by #receive).
    #
    def expressions_receive (emsg, eargs)

      wi, fei, exp = extract_info(emsg, eargs)

      begin

        return apply(eargs) if emsg == :apply && eargs[:tree]

        return unless exp
          # can't reply to a missing expression...

        case emsg
        when :apply then exp.apply
        when :reply then exp.do_reply(wi)
        when :cancel then exp.cancel
        end

      rescue Exception => e

        #puts
        #p e
        #e.backtrace.each { |l| puts l }
        #puts

        ex = if exp
          exp
        else
          RawExpression.new(@context, fei, eargs[:parent_id], eargs[:tree], wi)
        end
        ex.persist
          #
          # making sure there is at least 1 expression in the storage
          # so that engine#process_status yields something

        handle_on_error(emsg, eargs) && return
          # return if error got handled

        wqueue.emit(
          :errors,
          :s_expression_pool,
          { :error => e,
            :wfid => (exp ? exp.fei : fei).wfid,
            :message => [ :expressions, emsg, eargs ] })
      end
    end

    # Handling errors during apply/reply of expressions.
    #
    def handle_on_error (emsg, eargs)

      return false if emsg == :cancel
        # no error handling for error ocurring during :cancel

      _wi, _fei, exp = extract_info(emsg, eargs)

      exp =
        exp || temp_exp(eargs[:parent_id], eargs[:variables], eargs[:workitem])

      return false if exp.in_error

      oe_exp = exp.lookup_on(:error)

      return false unless oe_exp

      handler = oe_exp.on_error.to_s

      wqueue.emit(
        :processes, :on_error, :fei => oe_exp.fei, :handler => handler)
        # just a notification

      return false if handler == ''

      oe_exp.fail

      true # error was handled here.

    rescue Exception => e

      puts
      puts "== rescuing error handling"
      puts
      p [ emsg, eargs ]
      puts
      p e
      puts e.backtrace
      puts

      # simply let fail for now

      # TODO : maybe emit some kind of message

      false
    end

    # Launches a new process instance.
    # (triggered by received a [ :processes, :launch, ... ] event)
    #
    def launch (args)

      fei = new_fei(args[:wfid])

      tree = args[:tree]
      tree = DefineExpression.reorganize(expmap, tree) \
        if expmap.is_definition?(tree)

      wqueue.emit(
        :expressions, :apply,
        :tree => tree,
        :fei => fei,
        :workitem => args[:workitem],
        :variables => {})
    end

    # Cancels a process instance.
    # (triggered by received a [ :processes, :cancel, ... ] event)
    #
    def cancel (args)

      root_fei = new_fei(args[:wfid])
      cancel_expression(root_fei)
    end

    def new_fei (wfid)

      fei = FlowExpressionId.new
      fei.engine_id = engine.engine_id
      fei.wfid = wfid || wfidgen.generate
      fei.expid = '0'

      fei
    end
  end
end
