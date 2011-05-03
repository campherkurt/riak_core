%% -------------------------------------------------------------------
%%
%% chash: basic consistent hashing
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc A consistent hashing implementation.  The space described by the ring
%%      coincides with SHA-1 hashes, and so any two keys producing the same
%%      SHA-1 hash are considered identical within the ring.
%%
%% @reference Karger, D.; Lehman, E.; Leighton, T.; Panigrahy, R.; Levine, M.;
%% Lewin, D. (1997). "Consistent hashing and random trees". Proceedings of the
%% twenty-ninth annual ACM symposium on Theory of computing: 654~663. ACM Press
%% New York, NY, USA

-module(chash).
-author('Justin Sheehy <justin@basho.com>').
-author('Andy Gross <andy@basho.com>').

-export([fresh/2,update/3,lookup/2,members/1,size/1,nodes/1,
     successors/2,successors/3,
     predecessors/2,predecessors/3,
     contains_name/2,key_of/1,
     merge_rings/2]).
    
-define(RINGTOP, trunc(math:pow(2,160)-1)).  % SHA-1 space

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export_type([partition/0, index/0, bin_index/0, chash/0, chash_node/0]).

-type partition() :: non_neg_integer().
-type index() :: non_neg_integer().
-type bin_index() :: binary().
-type chash_node() :: term().
-type node_entry() :: {partition(), chash_node()}.
-type partition_count() :: pos_integer().
-opaque chash() :: {partition_count(), [node_entry()]}.


% @type index() = binary().
% Indices into the ring, used as keys for object location, are binary
% representations of 160-bit integers.

% @type chash_node() = term().
% A Node is the unique identifier for the owner of a given partition.
% An Erlang Pid works well here, but the chash module allows it to
% be any term.

% @doc Create a brand new ring.  The size and seednode are specified;
%      initially all partitions are owned by the seednode.  If NumPartitions
%      is not much larger than the intended eventual number of
%       participating nodes, then performance will suffer.
-spec fresh(partition_count(), node()) -> chash().
fresh(NumPartitions, SeedNode) ->
    Inc = ?RINGTOP div NumPartitions,
    {NumPartitions, [{IndexAsInt, SeedNode} ||
           IndexAsInt <- lists:seq(0,(?RINGTOP-1),Inc)]}.

% @doc Find the Node that owns the partition identified by IndexAsInt.
-spec lookup(partition(), chash()) -> chash_node().
lookup(IndexAsInt, CHash) ->
    {_NumPartitions, Nodes} = CHash,
    {IndexAsInt, X} = proplists:lookup(IndexAsInt, Nodes),
    X.

% @doc Return true if named Node owns any partitions in the ring, else false.
-spec contains_name(chash_node(), chash()) -> boolean().
contains_name(Name, CHash) ->
    {_NumPartitions, Nodes} = CHash,
    [X || {_,X} <- Nodes, X == Name] =/= [].

% @doc Make the partition beginning at IndexAsInt owned by Name'd node.
-spec update(partition(), chash_node(), chash()) -> chash().
update(IndexAsInt, Name, CHash) ->
    {NumPartitions, Nodes} = CHash,
    NewNodes = lists:keyreplace(IndexAsInt, 1, Nodes, {IndexAsInt, Name}),
    {NumPartitions, NewNodes}.

% @doc Given an object key, return all NodeEntries in order starting at Index.
-spec successors(bin_index(), chash()) -> [node_entry()].
successors(Index, CHash) when is_binary(Index) ->
    successors(Index, CHash, num_partitions(CHash)).
% @doc Given an object key, return the next N NodeEntries in order
%      starting at Index.
-spec successors(bin_index(), chash(), pos_integer()) -> [node_entry()].
successors(Index, CHash, N) ->
    Num = max_n(N, CHash),
    {Res, _} = lists:split(Num, ordered_from(Index, CHash)),
    Res.

% @doc Given an object key, return all NodeEntries in reverse order
%      starting at Index.
-spec predecessors(bin_index(), chash()) -> [node_entry()].
predecessors(Index, CHash) ->
    predecessors(Index, CHash, num_partitions(CHash)).
% @doc Given an object key, return the next N NodeEntries in reverse order
%      starting at Index.
-spec predecessors(bin_index(), chash(), pos_integer()) -> [node_entry()].
predecessors(Index, CHash, N) ->
    Num = max_n(N, CHash),
    {Res, _} = lists:split(Num, lists:reverse(ordered_from(Index,CHash))),
    Res.

% @doc Return either N or the number of partitions in the ring, whichever
%      is lesser.
-spec max_n(pos_integer(), chash()) -> pos_integer().
max_n(N, {NumPartitions, _Nodes}) ->
    erlang:min(N, NumPartitions).

% @doc Given an object key, return all NodeEntries in order starting at Index.
-spec ordered_from(bin_index(), chash()) -> [node_entry()].
ordered_from(Index, CHash) ->
    {NumPartitions, Nodes} = CHash,
    <<IndexAsInt:160/integer>> = Index,
    Inc = ?RINGTOP div NumPartitions,
    {A, B} = lists:split((IndexAsInt div Inc)+1, Nodes),
    B ++ A.

% @doc Given any term used to name an object, produce that object's key
%      into the ring.  Two names with the same SHA-1 hash value are
%      considered the same name.
-spec key_of(term()) -> bin_index().
key_of(ObjectName) ->    
    crypto:sha(term_to_binary(ObjectName)).

% @doc Return all Nodes that own any partitions in the ring.
-spec members(chash()) -> [chash_node()].
members(CHash) ->
    {_NumPartitions, Nodes} = CHash,
    lists:usort([X || {_Idx,X} <- Nodes]).

% @doc Return the entire set of NodeEntries in the ring.
-spec nodes(chash()) -> [node_entry()].
nodes(CHash) ->
    {_NumPartitions, Nodes} = CHash,
    Nodes.

% @doc Return a randomized merge of two rings.
%      If multiple nodes are actively claiming nodes in the same
%      time period, churn will occur.  Be prepared to live with it.
-spec merge_rings(chash(), chash()) -> chash().
merge_rings(CHashA,CHashB) ->
    {NumPartitions, NodesA} = CHashA,
    {NumPartitions, NodesB} = CHashB,
    {NumPartitions, [{I,randomnode(A,B)} || 
           {{I,A},{I,B}} <- lists:zip(NodesA,NodesB)]}.

-spec randomnode(chash_node(), chash_node()) -> chash_node().
randomnode(NodeA,NodeA) -> NodeA;
randomnode(NodeA,NodeB) -> lists:nth(random:uniform(2),[NodeA,NodeB]).

% @doc Return the number of partitions in the ring.
-spec size(chash()) -> pos_integer().
size(CHash) ->
    {_NumPartitions,Nodes} = CHash,
    length(Nodes).

-spec num_partitions(chash()) -> pos_integer().
num_partitions(CHash) ->
    element(1, CHash).

-ifdef(TEST).

update_test() ->
    Node = 'old@host', NewNode = 'new@host',
    
    % Create a fresh ring...
    CHash = chash:fresh(5, Node),
    GetNthIndex = fun(N, {_, Nodes}) -> {Index, _} = lists:nth(N, Nodes), Index end,
    
    % Test update...
    FirstIndex = GetNthIndex(1, CHash),
    ThirdIndex = GetNthIndex(3, CHash),
    {5, [{_, NewNode}, {_, Node}, {_, Node}, {_, Node}, {_, Node}, {_, Node}]} = update(FirstIndex, NewNode, CHash),
    {5, [{_, Node}, {_, Node}, {_, NewNode}, {_, Node}, {_, Node}, {_, Node}]} = update(ThirdIndex, NewNode, CHash).

contains_test() ->
    CHash = chash:fresh(8, the_node),
    ?assertEqual(true, contains_name(the_node,CHash)),
    ?assertEqual(false, contains_name(some_other_node,CHash)).

max_n_test() ->
    CHash = chash:fresh(8, the_node),
    ?assertEqual(1, max_n(1,CHash)),
    ?assertEqual(8, max_n(11,CHash)).
    
simple_size_test() ->
    ?assertEqual(8, length(chash:nodes(chash:fresh(8,the_node)))).

successors_length_test() ->
    ?assertEqual(8, length(chash:successors(chash:key_of(0),
                                            chash:fresh(8,the_node)))).
inverse_pred_test() ->
    CHash = chash:fresh(8,the_node),
    S = [I || {I,_} <- chash:successors(chash:key_of(4),CHash)],
    P = [I || {I,_} <- chash:predecessors(chash:key_of(4),CHash)],
    ?assertEqual(S,lists:reverse(P)).

merge_test() ->
    CHashA = chash:fresh(8,node_one),
    CHashB = chash:update(0,node_one,chash:fresh(8,node_two)),
    CHash = chash:merge_rings(CHashA,CHashB),
    ?assertEqual(node_one,chash:lookup(0,CHash)).

-endif.
