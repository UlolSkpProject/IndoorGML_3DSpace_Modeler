#include "reference_graph_pipeline.h"

#include <algorithm>
#include <cmath>
#include <functional>
#include <limits>
#include <queue>
#include <set>
#include <stdexcept>
#include <tuple>
#include <unordered_map>
#include <utility>

namespace
{
using namespace IndoorGMLAdjacencyNative;
constexpr double EPSILON = 1.0e-9;
constexpr double SLIVER_MAX_WIDTH_RATIO = 0.01;
// Degree-2 shortcuts are considered only when the interior angle is at least
// 150 degrees. Candidates nearest to a straight 180-degree continuation are
// contracted first.
constexpr double OPTIMIZED_MAX_COSINE = -0.86602540378443864676;

double distance(const Vec3& a, const Vec3& b)
{
    const double x=a.x-b.x,y=a.y-b.y,z=a.z-b.z;
    return std::sqrt(x*x+y*y+z*z);
}

std::vector<std::vector<std::size_t>> adjacency(const ReferenceGraphStageSnapshot& graph)
{
    std::vector<std::vector<std::size_t>> result(graph.nodes.size());
    for(const auto& edge:graph.edges)
    {
        if(edge.first>=graph.nodes.size() || edge.second>=graph.nodes.size() ||
           edge.first==edge.second) continue;
        result[edge.first].push_back(edge.second);
        result[edge.second].push_back(edge.first);
    }
    for(auto& list:result)
    {
        std::sort(list.begin(),list.end());
        list.erase(std::unique(list.begin(),list.end()),list.end());
    }
    return result;
}

bool has_edge(const std::vector<std::vector<std::size_t>>& adj,
              std::size_t a,std::size_t b)
{
    return std::binary_search(adj[a].begin(),adj[a].end(),b);
}

bool clear_segments(const CellData& cell,
                    const std::vector<std::pair<Vec3,Vec3>>& segments,
                    double tolerance)
{
    if(segments.empty()) return true;
    const auto checked=validate_room_reference_segments(cell,segments,tolerance);
    return checked.size()==segments.size() &&
        std::all_of(checked.begin(),checked.end(),[](bool value){return value;});
}

void canonicalize_edges(ReferenceGraphStageSnapshot& graph)
{
    for(auto& edge:graph.edges)
        if(edge.second<edge.first) std::swap(edge.first,edge.second);
    std::sort(graph.edges.begin(),graph.edges.end(),[](const auto& a,const auto& b){
        return std::tie(a.first,a.second)<std::tie(b.first,b.second);
    });
    graph.edges.erase(std::unique(graph.edges.begin(),graph.edges.end(),[](const auto& a,const auto& b){
        return a.first==b.first && a.second==b.second;
    }),graph.edges.end());
}

struct GraphBlock
{
    std::vector<std::size_t> vertices;
    std::vector<ReferenceGraphEdge> edges;
};

std::vector<GraphBlock> cyclic_biconnected_blocks(
    const ReferenceGraphStageSnapshot& graph)
{
    const auto adjacent=adjacency(graph);
    const std::size_t count=graph.nodes.size();
    std::vector<int> discovery(count,-1),low(count,-1),parent(count,-1);
    std::vector<ReferenceGraphEdge> stack;
    std::vector<GraphBlock> result;
    int tick=0;

    auto finish_block=[&](std::size_t first,std::size_t second){
        GraphBlock block;
        std::set<std::size_t> vertices;
        while(!stack.empty())
        {
            auto edge=stack.back();
            stack.pop_back();
            if(edge.second<edge.first) std::swap(edge.first,edge.second);
            block.edges.push_back(edge);
            vertices.insert(edge.first);
            vertices.insert(edge.second);
            if((edge.first==std::min(first,second) &&
                edge.second==std::max(first,second))) break;
        }
        block.vertices.assign(vertices.begin(),vertices.end());
        std::sort(block.edges.begin(),block.edges.end(),[](const auto& a,const auto& b){
            return std::tie(a.first,a.second)<std::tie(b.first,b.second);
        });
        block.edges.erase(std::unique(block.edges.begin(),block.edges.end(),
            [](const auto& a,const auto& b){
                return a.first==b.first && a.second==b.second;
            }),block.edges.end());
        if(block.vertices.size()>=3 && block.edges.size()>=block.vertices.size())
            result.push_back(std::move(block));
    };

    std::function<void(std::size_t)> visit;
    visit=[&](std::size_t node){
        discovery[node]=low[node]=tick++;
        for(const auto other:adjacent[node])
        {
            if(discovery[other]<0)
            {
                parent[other]=static_cast<int>(node);
                stack.push_back({node,other});
                visit(other);
                low[node]=std::min(low[node],low[other]);
                if(low[other]>=discovery[node]) finish_block(node,other);
            }
            else if(static_cast<int>(other)!=parent[node] &&
                    discovery[other]<discovery[node])
            {
                low[node]=std::min(low[node],discovery[other]);
                stack.push_back({node,other});
            }
        }
    };

    for(std::size_t node=0;node<count;++node)
    {
        if(discovery[node]>=0) continue;
        visit(node);
        stack.clear();
    }
    std::sort(result.begin(),result.end(),[](const GraphBlock& a,const GraphBlock& b){
        return a.vertices<b.vertices;
    });
    return result;
}

std::optional<std::vector<std::size_t>> sliver_chain(
    const ReferenceGraphStageSnapshot& graph,
    const GraphBlock& block,
    double tolerance)
{
    if(block.vertices.size()<3 || block.edges.size()<block.vertices.size())
        return std::nullopt;

    std::size_t first=block.vertices.front(),last=first;
    double axis_length_squared=0.0;
    for(std::size_t i=0;i<block.vertices.size();++i)
        for(std::size_t j=i+1;j<block.vertices.size();++j)
        {
            const auto& a=graph.nodes[block.vertices[i]].point;
            const auto& b=graph.nodes[block.vertices[j]].point;
            const double x=b.x-a.x,y=b.y-a.y,z=b.z-a.z;
            const double candidate=x*x+y*y+z*z;
            if(candidate>axis_length_squared)
            {
                axis_length_squared=candidate;
                first=block.vertices[i];
                last=block.vertices[j];
            }
        }
    if(!std::isfinite(axis_length_squared) ||
       axis_length_squared<=tolerance*tolerance) return std::nullopt;

    const double axis_length=std::sqrt(axis_length_squared);
    const auto& origin=graph.nodes[first].point;
    const auto& endpoint=graph.nodes[last].point;
    const double ax=(endpoint.x-origin.x)/axis_length;
    const double ay=(endpoint.y-origin.y)/axis_length;
    const double az=(endpoint.z-origin.z)/axis_length;
    const double max_width=std::max(tolerance,
                                    axis_length*SLIVER_MAX_WIDTH_RATIO);
    std::vector<std::pair<double,std::size_t>> projected;
    double actual_width=0.0;
    for(const auto index:block.vertices)
    {
        const auto& point=graph.nodes[index].point;
        const double dx=point.x-origin.x;
        const double dy=point.y-origin.y;
        const double dz=point.z-origin.z;
        const double along=dx*ax+dy*ay+dz*az;
        double perpendicular_squared=dx*dx+dy*dy+dz*dz-along*along;
        perpendicular_squared=std::max(0.0,perpendicular_squared);
        const double perpendicular=std::sqrt(perpendicular_squared);
        if(!std::isfinite(along) || !std::isfinite(perpendicular) ||
           along<-tolerance || along>axis_length+tolerance ||
           perpendicular>max_width+EPSILON) return std::nullopt;
        actual_width=std::max(actual_width,perpendicular);
        projected.push_back({along,index});
    }
    std::sort(projected.begin(),projected.end(),[](const auto& a,const auto& b){
        if(a.first!=b.first) return a.first<b.first;
        return a.second<b.second;
    });
    const double minimum_progress=std::max(tolerance,2.0*actual_width);
    for(std::size_t i=1;i<projected.size();++i)
        if(projected[i].first-projected[i-1].first<=minimum_progress)
            return std::nullopt;

    std::vector<std::size_t> result;
    result.reserve(projected.size());
    for(const auto& item:projected) result.push_back(item.second);
    return result;
}

void linearize_sliver_components(ReferenceGraphStageSnapshot& graph,
                                 const CellData& cell,
                                 double tolerance)
{
    canonicalize_edges(graph);
    const auto blocks=cyclic_biconnected_blocks(graph);
    for(const auto& block:blocks)
    {
        const auto chain=sliver_chain(graph,block,tolerance);
        if(!chain) continue;

        const auto adjacent=adjacency(graph);
        std::vector<std::pair<Vec3,Vec3>> checks;
        for(std::size_t i=1;i<chain->size();++i)
            if(!has_edge(adjacent,(*chain)[i-1],(*chain)[i]))
                checks.push_back({graph.nodes[(*chain)[i-1]].point,
                                  graph.nodes[(*chain)[i]].point});
        if(!clear_segments(cell,checks,tolerance)) continue;

        std::set<std::pair<std::size_t,std::size_t>> internal;
        for(auto edge:block.edges)
        {
            if(edge.second<edge.first) std::swap(edge.first,edge.second);
            internal.insert({edge.first,edge.second});
        }
        graph.edges.erase(std::remove_if(graph.edges.begin(),graph.edges.end(),
            [&](ReferenceGraphEdge edge){
                if(edge.second<edge.first) std::swap(edge.first,edge.second);
                return internal.count({edge.first,edge.second})>0;
            }),graph.edges.end());
        for(std::size_t i=1;i<chain->size();++i)
            graph.edges.push_back({(*chain)[i-1],(*chain)[i]});
        canonicalize_edges(graph);
    }
}

bool contract_fresh(ReferenceGraphStageSnapshot& graph,
                    const CellData& cell,
                    const std::vector<std::size_t>& members,
                    const ReferenceGraphNode& representative,
                    const std::set<std::size_t>& certified_originals,
                    double tolerance)
{
    if(members.size()<3) return false;
    const auto adj=adjacency(graph);
    std::vector<bool> selected(graph.nodes.size(),false);
    for(const auto index:members)
    {
        if(index>=graph.nodes.size() || graph.protected_nodes[index]) return false;
        selected[index]=true;
    }
    std::set<std::size_t> boundary;
    for(const auto index:members)
        for(const auto other:adj[index]) if(!selected[other]) boundary.insert(other);
    std::vector<std::pair<Vec3,Vec3>> checks;
    auto certified=[&](std::size_t index){
        const auto origin=graph.original_indices[index];
        return origin && certified_originals.count(*origin)>0;
    };
    for(const auto index:members)
        if(!certified(index)) checks.push_back({representative.point,graph.nodes[index].point});
    for(const auto index:boundary)
        if(!certified(index)) checks.push_back({representative.point,graph.nodes[index].point});
    if(!clear_segments(cell,checks,tolerance)) return false;

    std::vector<bool> removed(graph.nodes.size(),false);
    for(const auto index:members) removed[index]=true;
    std::vector<std::size_t> remap(graph.nodes.size(),std::numeric_limits<std::size_t>::max());
    ReferenceGraphStageSnapshot result;
    for(std::size_t old=0;old<graph.nodes.size();++old)
    {
        if(removed[old]) continue;
        remap[old]=result.nodes.size();
        result.nodes.push_back(graph.nodes[old]);
        result.original_indices.push_back(graph.original_indices[old]);
        result.protected_nodes.push_back(graph.protected_nodes[old]);
    }
    const std::size_t rep=result.nodes.size();
    result.nodes.push_back(representative);
    result.original_indices.push_back(std::nullopt);
    result.protected_nodes.push_back(true);
    for(const auto& edge:graph.edges)
    {
        if(removed[edge.first] || removed[edge.second]) continue;
        result.edges.push_back({remap[edge.first],remap[edge.second]});
    }
    for(const auto old:boundary) result.edges.push_back({rep,remap[old]});
    canonicalize_edges(result);
    graph=std::move(result);
    return true;
}

double loop_area(const ReferenceGraphStageSnapshot& graph,
                 const std::vector<std::size_t>& vertices)
{
    double nx=0,ny=0,nz=0;
    for(std::size_t i=0;i<vertices.size();++i)
    {
        const auto& a=graph.nodes[vertices[i]].point;
        const auto& b=graph.nodes[vertices[(i+1)%vertices.size()]].point;
        nx+=a.y*b.z-a.z*b.y;
        ny+=a.z*b.x-a.x*b.z;
        nz+=a.x*b.y-a.y*b.x;
    }
    return 0.5*std::sqrt(nx*nx+ny*ny+nz*nz);
}

ReferenceGraphStageSnapshot build_collapsed(const CellData& cell,
                                            const ReferenceGraphDebug& before,
                                            ReferenceGraphStageSnapshot graph,
                                            double tolerance)
{
    // A cyclic block whose reference points have one unambiguous longitudinal
    // order is a line with redundant chords, not an area-bearing loop. Reduce
    // it to that path before certified polygon loops are contracted.
    linearize_sliver_components(graph,cell,tolerance);

    std::vector<std::size_t> order(before.loop_candidates.size());
    for(std::size_t i=0;i<order.size();++i) order[i]=i;
    std::sort(order.begin(),order.end(),[&](std::size_t a,std::size_t b){
        const auto& x=before.loop_candidates[a];
        const auto& y=before.loop_candidates[b];
        if(x.vertices.size()!=y.vertices.size()) return x.vertices.size()<y.vertices.size();
        return x.vertices<y.vertices;
    });
    std::set<std::size_t> reserved;
    for(const auto candidate_index:order)
    {
        const auto& candidate=before.loop_candidates[candidate_index];
        if(candidate.vertices.empty() ||
           std::any_of(candidate.vertices.begin(),candidate.vertices.end(),
                       [&](std::size_t id){return reserved.count(id)>0;})) continue;
        std::unordered_map<std::size_t,std::size_t> current;
        for(std::size_t i=0;i<graph.original_indices.size();++i)
            if(graph.original_indices[i]) current[*graph.original_indices[i]]=i;
        std::vector<std::size_t> members;
        bool missing=false;
        for(const auto id:candidate.vertices)
        {
            const auto found=current.find(id);
            if(found==current.end()){missing=true;break;}
            members.push_back(found->second);
        }
        if(missing) continue;
        if(before.state_node_index &&
           std::find(candidate.vertices.begin(),candidate.vertices.end(),
                     *before.state_node_index)!=candidate.vertices.end()) continue;
        const auto adj=adjacency(graph);
        bool ring=true;
        for(std::size_t i=0;i<members.size();++i)
            if(!has_edge(adj,members[i],members[(i+1)%members.size()])){ring=false;break;}
        if(!ring || !(loop_area(graph,members)>0.0)) continue;
        std::set<std::size_t> certified(candidate.vertices.begin(),candidate.vertices.end());
        certified.insert(candidate.visible_neighbors.begin(),candidate.visible_neighbors.end());
        ReferenceGraphStageSnapshot attempt=graph;
        for(const auto index:members) attempt.protected_nodes[index]=false;
        if(contract_fresh(attempt,cell,members,candidate.representative,certified,tolerance))
        {
            graph=std::move(attempt);
            reserved.insert(candidate.vertices.begin(),candidate.vertices.end());
        }
    }
    return graph;
}

bool projected_between(const Vec3& a,const Vec3& b,const Vec3& c)
{
    const double x=c.x-a.x,y=c.y-a.y,z=c.z-a.z;
    const double length=x*x+y*y+z*z;
    if(!std::isfinite(length) || length<=EPSILON*EPSILON) return false;
    const double t=((b.x-a.x)*x+(b.y-a.y)*y+(b.z-a.z)*z)/length;
    return std::isfinite(t) && t>EPSILON && t<1.0-EPSILON;
}

struct DegreeTwoCandidate
{
    double straightness=0.0; // -cos(angle): 1.0 at 180 degrees.
    std::size_t node=0;
    std::size_t version=0;
};

struct DegreeTwoCandidateLess
{
    bool operator()(const DegreeTwoCandidate& a,const DegreeTwoCandidate& b) const
    {
        if(a.straightness!=b.straightness)
            return a.straightness<b.straightness;
        // Stable lower node identity wins equal-angle ties.
        return a.node>b.node;
    }
};

std::optional<DegreeTwoCandidate> degree_two_candidate(
    const ReferenceGraphStageSnapshot& graph,
    const std::vector<std::set<std::size_t>>& links,
    const std::vector<bool>& alive,
    const std::vector<std::size_t>& versions,
    std::size_t middle)
{
    if(middle>=graph.nodes.size() || !alive[middle] ||
       middle>=graph.protected_nodes.size() || graph.protected_nodes[middle] ||
       links[middle].size()!=2) return std::nullopt;

    auto iterator=links[middle].begin();
    const std::size_t first=*iterator++;
    const std::size_t second=*iterator;
    if(!alive[first] || !alive[second]) return std::nullopt;

    const auto& a=graph.nodes[first].point;
    const auto& b=graph.nodes[middle].point;
    const auto& c=graph.nodes[second].point;
    if(!projected_between(a,b,c)) return std::nullopt;

    const double ux=a.x-b.x,uy=a.y-b.y,uz=a.z-b.z;
    const double vx=c.x-b.x,vy=c.y-b.y,vz=c.z-b.z;
    const double u_length=std::sqrt(ux*ux+uy*uy+uz*uz);
    const double v_length=std::sqrt(vx*vx+vy*vy+vz*vz);
    if(!std::isfinite(u_length) || !std::isfinite(v_length) ||
       u_length<=EPSILON || v_length<=EPSILON) return std::nullopt;

    double cosine=(ux*vx+uy*vy+uz*vz)/(u_length*v_length);
    cosine=std::max(-1.0,std::min(1.0,cosine));
    if(cosine>OPTIMIZED_MAX_COSINE+EPSILON) return std::nullopt;
    return DegreeTwoCandidate{-cosine,middle,versions[middle]};
}

ReferenceGraphStageSnapshot build_optimized(const CellData& cell,
                                            ReferenceGraphStageSnapshot graph,
                                            double tolerance)
{
    const std::size_t count=graph.nodes.size();
    std::vector<std::set<std::size_t>> links(count);
    for(const auto& edge:graph.edges)
    {
        if(edge.first>=count || edge.second>=count || edge.first==edge.second) continue;
        links[edge.first].insert(edge.second);
        links[edge.second].insert(edge.first);
    }
    std::vector<bool> alive(count,true);
    std::vector<std::size_t> versions(count,0);
    std::priority_queue<DegreeTwoCandidate,
                        std::vector<DegreeTwoCandidate>,
                        DegreeTwoCandidateLess> candidates;
    auto enqueue=[&](std::size_t node){
        const auto candidate=degree_two_candidate(graph,links,alive,versions,node);
        if(candidate) candidates.push(*candidate);
    };
    for(std::size_t node=0;node<count;++node) enqueue(node);

    while(!candidates.empty())
    {
        const auto queued=candidates.top();
        candidates.pop();
        if(queued.node>=count || queued.version!=versions[queued.node]) continue;
        const auto current=degree_two_candidate(graph,links,alive,versions,queued.node);
        if(!current || std::abs(current->straightness-queued.straightness)>EPSILON) continue;

        auto iterator=links[queued.node].begin();
        const std::size_t representative=*iterator++;
        const std::size_t other=*iterator;
        const bool direct=links[representative].count(other)>0;
        if(!direct && !clear_segments(cell,{{graph.nodes[representative].point,
                                             graph.nodes[other].point}},tolerance)) continue;

        links[representative].erase(queued.node);
        links[other].erase(queued.node);
        links[queued.node].clear();
        if(!direct)
        {
            links[representative].insert(other);
            links[other].insert(representative);
        }
        alive[queued.node]=false;
        ++versions[queued.node];
        ++versions[representative];
        ++versions[other];
        enqueue(representative);
        enqueue(other);
    }

    std::vector<std::size_t> remap(count,std::numeric_limits<std::size_t>::max());
    ReferenceGraphStageSnapshot result;
    for(std::size_t old=0;old<count;++old)
    {
        if(!alive[old]) continue;
        remap[old]=result.nodes.size();
        result.nodes.push_back(graph.nodes[old]);
        result.original_indices.push_back(graph.original_indices[old]);
        result.protected_nodes.push_back(graph.protected_nodes[old]);
    }
    for(std::size_t first=0;first<count;++first)
    {
        if(!alive[first]) continue;
        for(const auto second:links[first])
        {
            if(first>=second || !alive[second]) continue;
            result.edges.push_back({remap[first],remap[second]});
        }
    }
    canonicalize_edges(result);
    return result;
}

std::vector<bool> reachable_nodes(const ReferenceGraphStageSnapshot& graph,
                                  std::size_t root)
{
    std::vector<bool> reached(graph.nodes.size(),false);
    if(root>=graph.nodes.size()) return reached;
    const auto adj=adjacency(graph);
    std::vector<std::size_t> queue{root};
    reached[root]=true;
    for(std::size_t head=0;head<queue.size();++head)
        for(const auto next:adj[queue[head]])
        {
            if(reached[next]) continue;
            reached[next]=true;
            queue.push_back(next);
        }
    return reached;
}

ReferenceGraphStageSnapshot build_full_los_graph(
    const ReferenceGraphStageSnapshot& optimized,const FaceSolid& solid,
    double tolerance)
{
    // Do not inherit any OPTIMIZED Edge: geometry alone determines visibility.
    // Keep all nodes, their indices and protected/owner metadata unchanged.
    ReferenceGraphStageSnapshot result=optimized;
    result.edges.clear();
    if(!solid.valid()) return result;

    const std::size_t count=result.nodes.size();
    std::vector<bool> valid(count,false);
    for(std::size_t i=0;i<count;++i)
        valid[i]=solid.inside(result.nodes[i].point,tolerance);

    for(std::size_t i=0;i<count;++i)
    {
        if(!valid[i]) continue;
        for(std::size_t j=i+1;j<count;++j)
        {
            if(!valid[j]) continue;
            if(solid.visible(result.nodes[i].point,result.nodes[j].point,tolerance))
                result.edges.push_back({i,j});
        }
    }
    // The strictly increasing (i,j) walk already produces canonical edges.
    return result;
}

ReferenceConnectivityRepairResult repair_connectivity(
    const ReferenceGraphStageSnapshot& los_graph,
    const ReferenceGraphStageSnapshot& before,
    const ReferenceGraphStageSnapshot& collapsed,
    std::size_t root,const FaceSolid& solid,double tolerance)
{
    ReferenceConnectivityRepairResult result{los_graph,0};
    if(root>=los_graph.nodes.size() || !solid.valid()) return result;
    const auto reached=reachable_nodes(los_graph,root);
    if(std::all_of(reached.begin(),reached.end(),[](bool b){return b;}))
        return result;

    // Restore only validated references discarded by the reductions, including
    // original BEFORE nodes and certified COLLAPSED representatives.
    ReferenceGraphStageSnapshot possible=los_graph;
    const std::size_t original_count=possible.nodes.size();
    const auto collect=[&](const ReferenceGraphStageSnapshot& source){
        for(std::size_t i=0;i<source.nodes.size();++i)
        {
            const auto& node=source.nodes[i];
            if(!solid.inside(node.point,tolerance)) continue;
            bool duplicate=false;
            for(const auto& existing:possible.nodes)
                if(distance(existing.point,node.point)<=tolerance)
                {duplicate=true;break;}
            if(duplicate) continue;
            possible.nodes.push_back(node);
            possible.original_indices.push_back(
                i<source.original_indices.size() ? source.original_indices[i] :
                std::nullopt);
            possible.protected_nodes.push_back(true);
        }
    };
    collect(before);
    collect(collapsed);
    if(possible.nodes.size()==original_count) return result;

    // A temporary full visibility graph finds multi-hop paths through removed
    // reference nodes. Prefer fewer added nodes, then shorter routes.
    // All original LOS nodes and edges remain unchanged.
    const auto candidates=build_full_los_graph(possible,solid,tolerance);
    const auto adj=adjacency(candidates);
    using Cost=std::pair<std::size_t,double>;
    using QueueEntry=std::tuple<std::size_t,double,std::size_t>;
    const Cost unreachable{
        std::numeric_limits<std::size_t>::max(),
        std::numeric_limits<double>::infinity()};
    std::vector<Cost> best(candidates.nodes.size(),unreachable);
    std::vector<std::optional<std::size_t>> parent(candidates.nodes.size());
    std::priority_queue<QueueEntry,std::vector<QueueEntry>,
                        std::greater<QueueEntry>> queue;
    best[root]={0,0.0};
    queue.push({0,0.0,root});
    while(!queue.empty())
    {
        const auto [new_count,length_so_far,current]=queue.top();
        queue.pop();
        if(best[current]!=Cost{new_count,length_so_far}) continue;
        for(const auto next:adj[current])
        {
            const Cost candidate{
                new_count+static_cast<std::size_t>(next>=original_count),
                length_so_far+distance(candidates.nodes[current].point,
                                       candidates.nodes[next].point)};
            if(candidate>=best[next]) continue;
            best[next]=candidate;
            parent[next]=current;
            queue.push({candidate.first,candidate.second,next});
        }
    }

    std::vector<bool> restore(candidates.nodes.size(),false);
    for(std::size_t target=0;target<original_count;++target)
    {
        if(reached[target] || best[target].first==unreachable.first) continue;
        std::size_t current=target;
        for(std::size_t step=0;step<candidates.nodes.size();++step)
        {
            if(current==root) break;
            if(current>=original_count) restore[current]=true;
            if(!parent[current]) break;
            current=*parent[current];
        }
    }
    for(std::size_t i=original_count;i<candidates.nodes.size();++i)
    {
        if(!restore[i]) continue;
        result.graph.nodes.push_back(candidates.nodes[i]);
        result.graph.original_indices.push_back(candidates.original_indices[i]);
        result.graph.protected_nodes.push_back(true);
        ++result.added_nodes;
    }
    if(result.added_nodes)
        result.graph=build_full_los_graph(result.graph,solid,tolerance);
    return result;
}

ReferenceGraphShortestPathTree bake_tree(const ReferenceGraphStageSnapshot& graph,
                                         std::size_t root)
{
    if(root>=graph.nodes.size()) throw std::invalid_argument("Reference State node is outside graph");
    ReferenceGraphShortestPathTree tree;
    tree.root=root;
    tree.distances.assign(graph.nodes.size(),std::numeric_limits<double>::infinity());
    tree.previous.assign(graph.nodes.size(),std::nullopt);
    using Entry=std::pair<double,std::size_t>;
    std::priority_queue<Entry,std::vector<Entry>,std::greater<Entry>> queue;
    const auto adj=adjacency(graph);
    tree.distances[root]=0.0;
    queue.push({0.0,root});
    while(!queue.empty())
    {
        const auto [cost,current]=queue.top(); queue.pop();
        if(cost!=tree.distances[current]) continue;
        for(const auto next:adj[current])
        {
            const double candidate=cost+distance(graph.nodes[current].point,graph.nodes[next].point);
            if(candidate<tree.distances[next] ||
               (candidate==tree.distances[next] &&
                (!tree.previous[next] || current<*tree.previous[next])))
            {
                tree.distances[next]=candidate;
                tree.previous[next]=current;
                queue.push({candidate,next});
            }
        }
    }
    return tree;
}
} // namespace

namespace IndoorGMLAdjacencyNative
{
ReferenceConnectivityRepairResult repair_reference_connectivity(
    const ReferenceGraphStageSnapshot& los_graph,
    const ReferenceGraphStageSnapshot& before,
    const ReferenceGraphStageSnapshot& collapsed,
    std::size_t state_node_index,const FaceSolid& solid,double tolerance)
{
    return repair_connectivity(los_graph,before,collapsed,
                               state_node_index,solid,tolerance);
}

ReferenceGraphPipeline build_state_reference_graph_pipeline(
    const Vec3& state_point,const CellData& cell,double tolerance)
{
    ReferenceGraphPipeline result;
    result.before.nodes.push_back({state_point,0.0});
    result.before.original_indices.push_back(0);
    result.before.protected_nodes.push_back(true);
    result.collapsed=result.before;
    result.optimized=result.before;
    result.los_graph=result.optimized;
    result.repaired_graph=result.los_graph;
    result.state_node_index=0;
    result.shortest_path_tree.root=0;
    result.shortest_path_tree.distances.push_back(0.0);
    result.shortest_path_tree.previous.push_back(std::nullopt);
    result.waypoint_solid=std::make_shared<FaceSolid>(cell,tolerance);
    result.waypoint_tolerance=tolerance;
    result.legacy_state_only=true;
    return result;
}

ReferenceGraphPipeline build_reference_graph_pipeline(
    const CellData& cell,const ReferenceGraphDebug& before,double tolerance)
{
    if(!before.state_node_index || *before.state_node_index>=before.nodes.size())
        throw std::invalid_argument("Reference BEFORE graph has no valid State node");
    ReferenceGraphPipeline result;
    result.before.nodes=before.nodes;
    result.before.edges=before.edges;
    result.before.original_indices.reserve(before.nodes.size());
    result.before.protected_nodes.assign(before.nodes.size(),false);
    for(std::size_t i=0;i<before.nodes.size();++i) result.before.original_indices.push_back(i);
    canonicalize_edges(result.before);
    // Preserve the State and certified loop anchors formerly protected by
    // AFTER. No radius-based reduction is performed here.
    result.before.protected_nodes[*before.state_node_index]=true;
    for(const auto& candidate:before.loop_candidates)
    {
        for(const auto index:candidate.vertices)
            if(index<result.before.nodes.size())
                result.before.protected_nodes[index]=true;
        for(const auto index:candidate.visible_neighbors)
            if(index<result.before.nodes.size())
                result.before.protected_nodes[index]=true;
    }
    result.collapsed=build_collapsed(cell,before,result.before,tolerance);
    result.optimized=build_optimized(cell,result.collapsed,tolerance);

    const auto state_original=*before.state_node_index;
    const auto found=std::find(result.optimized.original_indices.begin(),
                               result.optimized.original_indices.end(),
                               std::optional<std::size_t>(state_original));
    if(found==result.optimized.original_indices.end())
        throw std::runtime_error("Reference State node did not survive Native reductions");
    result.state_node_index=static_cast<std::size_t>(found-result.optimized.original_indices.begin());
    // Build FaceSolid once: the identical 3D visibility contract is used
    // for full pairwise Ref-Node LOS and the final waypoint gateway check.
    result.waypoint_solid=std::make_shared<FaceSolid>(cell,tolerance);
    result.waypoint_tolerance=tolerance;
    result.los_graph=build_full_los_graph(
        result.optimized,*result.waypoint_solid,tolerance);
    auto repaired=repair_reference_connectivity(
        result.los_graph,result.before,result.collapsed,
        result.state_node_index,*result.waypoint_solid,tolerance);
    result.repaired_graph=std::move(repaired.graph);
    result.recovered_node_count=repaired.added_nodes;
    result.shortest_path_tree=bake_tree(
        result.repaired_graph,result.state_node_index);
    result.unreachable_node_count=static_cast<std::size_t>(std::count_if(
        result.shortest_path_tree.distances.begin(),
        result.shortest_path_tree.distances.end(),
        [](double value){return !std::isfinite(value);}));

    return result;
}

namespace
{
Vec3 frame_point(const std::array<double,16>& m,const Vec3& p)
{
    return {m[0]*p.x+m[4]*p.y+m[8]*p.z+m[12],
            m[1]*p.x+m[5]*p.y+m[9]*p.z+m[13],
            m[2]*p.x+m[6]*p.y+m[10]*p.z+m[14]};
}
Vec3 frame_direction(const std::array<double,16>& m,const Vec3& p)
{
    return {m[0]*p.x+m[4]*p.y+m[8]*p.z,
            m[1]*p.x+m[5]*p.y+m[9]*p.z,
            m[2]*p.x+m[6]*p.y+m[10]*p.z};
}
double frame_dot(const Vec3& a,const Vec3& b)
{
    return a.x*b.x+a.y*b.y+a.z*b.z;
}
void require_rigid_frame(const std::array<double,16>& m)
{
    for(double v:m) if(!std::isfinite(v))
        throw std::invalid_argument("Reference CellSpace frame must be finite");
    if(std::abs(m[3])>1e-8 || std::abs(m[7])>1e-8 ||
       std::abs(m[11])>1e-8 || std::abs(m[15]-1.0)>1e-8)
        throw std::invalid_argument("Reference CellSpace frame must be affine");
    const Vec3 x{m[0],m[1],m[2]};
    const Vec3 y{m[4],m[5],m[6]};
    const Vec3 z{m[8],m[9],m[10]};
    if(std::abs(frame_dot(x,x)-1.0)>1e-6 ||
       std::abs(frame_dot(y,y)-1.0)>1e-6 ||
       std::abs(frame_dot(z,z)-1.0)>1e-6 ||
       std::abs(frame_dot(x,y))>1e-6 ||
       std::abs(frame_dot(y,z))>1e-6 ||
       std::abs(frame_dot(z,x))>1e-6)
        throw std::invalid_argument("Scaled/skewed CellSpace invalidates Reference path lengths");
    const double det=frame_dot(x,{
        y.y*z.z-y.z*z.y,y.z*z.x-y.x*z.z,y.x*z.y-y.y*z.x});
    if(std::abs(det-1.0)>1e-6)
        throw std::invalid_argument("Reference CellSpace frame must preserve orientation");
}
CellData localized_cell(const CellData& source,const std::array<double,16>& m)
{
    CellData result=source;
    Vec3 low{std::numeric_limits<double>::infinity(),
             std::numeric_limits<double>::infinity(),
             std::numeric_limits<double>::infinity()};
    Vec3 high{-low.x,-low.y,-low.z};
    for(int x=0;x<2;++x) for(int y=0;y<2;++y) for(int z=0;z<2;++z)
    {
        const Vec3 p=frame_point(m,{
            x?source.bounds.maximum.x:source.bounds.minimum.x,
            y?source.bounds.maximum.y:source.bounds.minimum.y,
            z?source.bounds.maximum.z:source.bounds.minimum.z});
        low.x=std::min(low.x,p.x);low.y=std::min(low.y,p.y);low.z=std::min(low.z,p.z);
        high.x=std::max(high.x,p.x);high.y=std::max(high.y,p.y);high.z=std::max(high.z,p.z);
    }
    result.bounds={low,high};
    for(auto& face:result.faces)
    {
        for(auto& p:face.outer_points) p=frame_point(m,p);
        for(auto& loop:face.inner_loops) for(auto& p:loop) p=frame_point(m,p);
        for(auto& triangle:face.triangles)
            for(auto& p:triangle.points) p=frame_point(m,p);
        face.normal=frame_direction(m,face.normal);
        if(face.has_plane)
        {
            face.plane.normal=frame_direction(m,face.plane.normal);
            face.plane.d=face.plane.d-frame_dot(face.plane.normal,
                                                   {m[12],m[13],m[14]});
        }
    }
    return result;
}
} // namespace

void finalize_reference_graph_local(
    ReferenceGraphPipeline& pipeline,const CellData& root_cell,
    const std::array<double,16>& root_to_local)
{
    require_rigid_frame(root_to_local);
    // Preserve radius, edge weights and shortest-path tree for rigid frames.
    for(auto* stage:{&pipeline.before,&pipeline.collapsed,
                     &pipeline.optimized,&pipeline.los_graph,&pipeline.repaired_graph})
        for(auto& node:stage->nodes)
            node.point=frame_point(root_to_local,node.point);
    const CellData local_cell=localized_cell(root_cell,root_to_local);
    pipeline.waypoint_solid=std::make_shared<FaceSolid>(
        local_cell,pipeline.waypoint_tolerance);
}

const ReferenceGraphStageSnapshot& reference_graph_stage(
    const ReferenceGraphPipeline& pipeline,ReferenceGraphStage stage)
{
    switch(stage)
    {
    case ReferenceGraphStage::Before:return pipeline.before;
    case ReferenceGraphStage::Collapsed:return pipeline.collapsed;
    case ReferenceGraphStage::Optimized:return pipeline.optimized;
    case ReferenceGraphStage::LosGraph:return pipeline.los_graph;
    case ReferenceGraphStage::ConnectivityRepair:return pipeline.repaired_graph;
    case ReferenceGraphStage::ShortPathGraph:
        throw std::invalid_argument("Short-path graph is a derived snapshot; use reference_short_path_graph");
    }
    throw std::invalid_argument("Unknown Reference Graph stage");
}

ReferenceGraphStageSnapshot reference_short_path_graph(
    const ReferenceGraphPipeline& pipeline)
{
    ReferenceGraphStageSnapshot result=pipeline.repaired_graph;
    result.edges.clear();
    const auto& tree=pipeline.shortest_path_tree;
    const std::size_t count=result.nodes.size();
    if(count==0 || tree.root>=count ||
       tree.previous.size()!=count || tree.distances.size()!=count)
        return result;

    for(std::size_t index=0;index<count;++index)
    {
        // Unreachable repaired graph nodes stay visible but have no SPT edge.
        if(index==tree.root || !std::isfinite(tree.distances[index]))
            continue;
        const auto parent=tree.previous[index];
        if(!parent || *parent>=count ||
           !std::isfinite(tree.distances[*parent]) || *parent==index)
            continue;
        result.edges.push_back({index,*parent});
    }
    canonicalize_edges(result);
    return result;
}

std::optional<Vec3> closest_reachable_reference_point(
    const ReferenceGraphPipeline& pipeline,const Vec3& waypoint)
{
    const auto& graph=pipeline.repaired_graph;
    const auto& tree=pipeline.shortest_path_tree;
    if(graph.nodes.empty() || tree.distances.size()!=graph.nodes.size())
        return std::nullopt;
    std::optional<std::size_t> closest;
    double best=std::numeric_limits<double>::infinity();
    for(std::size_t i=0;i<graph.nodes.size();++i)
    {
        if(!std::isfinite(tree.distances[i])) continue;
        const double candidate=distance(graph.nodes[i].point,waypoint);
        if(candidate<best || (candidate==best && (!closest || i<*closest)))
        {
            best=candidate;
            closest=i;
        }
    }
    return closest ? std::optional<Vec3>(graph.nodes[*closest].point) :
                     std::nullopt;
}

namespace
{
// A transition waypoint lies on a shared CellSpace Face. FaceSolid::visible
// correctly rejects boundary endpoints, so verify an interior endpoint
// a few tolerances before the waypoint along the same segment instead.
// The original waypoint remains the exact final path point.
bool waypoint_reference_visible(const FaceSolid& solid,const Vec3& node,
                                const Vec3& waypoint,double tolerance)
{
    const double length=distance(node,waypoint);
    if(length<=EPSILON) return solid.inside(node,tolerance);
    if(solid.visible(node,waypoint,tolerance)) return true;

    const double inset=tolerance*8.0;
    if(!std::isfinite(length) || length<=inset+2.0*tolerance ||
       !std::isfinite(inset) || inset<=0.0 ||
       solid.nearest_distance(waypoint)>inset)
        return false;

    const double t=inset/length;
    const Vec3 interior{
        waypoint.x+(node.x-waypoint.x)*t,
        waypoint.y+(node.y-waypoint.y)*t,
        waypoint.z+(node.z-waypoint.z)*t
    };
    return solid.visible(node,interior,tolerance);
}
} // namespace

std::vector<Vec3> reference_transition_polyline(
    const ReferenceGraphPipeline& pipeline,const Vec3& waypoint)
{
    const auto& graph=pipeline.repaired_graph;
    const auto& tree=pipeline.shortest_path_tree;
    if(graph.nodes.empty() || tree.distances.size()!=graph.nodes.size())
        return {};
    const bool has_visibility= pipeline.waypoint_solid && pipeline.waypoint_solid->valid();
    // The legacy State-only fallback can lack a valid Face Solid. Retain its
    // existing direct route; every normal Reference graph requires verified LOS.
    if(!has_visibility && !pipeline.legacy_state_only) return {};
    std::optional<std::size_t> gateway;
    double best=std::numeric_limits<double>::infinity();
    for(std::size_t i=0;i<graph.nodes.size();++i)
    {
        if(!std::isfinite(tree.distances[i])) continue;
        const double direct=distance(graph.nodes[i].point,waypoint);
        if(has_visibility &&
           !waypoint_reference_visible(*pipeline.waypoint_solid,
                                       graph.nodes[i].point,waypoint,
                                       pipeline.waypoint_tolerance)) continue;
        const double candidate=tree.distances[i]+direct;
        if(candidate<best || (candidate==best && (!gateway || i<*gateway)))
        {best=candidate;gateway=i;}
    }
    if(!gateway) return {};
    std::vector<std::size_t> reversed;
    std::size_t current=*gateway;
    for(std::size_t count=0;count<=graph.nodes.size();++count)
    {
        reversed.push_back(current);
        if(current==tree.root) break;
        if(!tree.previous[current]) return {};
        current=*tree.previous[current];
    }
    if(reversed.back()!=tree.root) return {};
    std::reverse(reversed.begin(),reversed.end());
    std::vector<Vec3> result;
    result.reserve(reversed.size()+1);
    for(const auto index:reversed) result.push_back(graph.nodes[index].point);
    if(result.empty() || distance(result.back(),waypoint)>EPSILON) result.push_back(waypoint);
    return result;
}
} // namespace IndoorGMLAdjacencyNative
