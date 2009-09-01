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


require 'ruote/engine/context'
require 'ruote/queue/subscriber'
require 'ruote/storage/base'


module Ruote

  #
  # Dumb Hash based in-memory storage.
  #
  # Warning : not constrained at all. May eat up all your mem.
  #           For testing purposes only !
  #
  class HashStorage < Hash

    include EngineContext
    include StorageBase # which overrides #context=
    include DummyTickets
    include Subscriber

    def find_expressions (query={})

      values.select { |exp| exp_match?(exp, query) }
    end

    def to_s

      inject('') do |s, (k, v)|
        s << "#{k.to_s} => #{v.class}\n"
      end
    end

    # Returns the expression for the given fei, if any.
    #
    def [] (fei)

      exp = super(fei)
      exp.context = context if exp

      exp
    end
  end
end
