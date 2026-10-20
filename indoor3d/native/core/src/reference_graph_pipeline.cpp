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
#include <unordered_set>
#include <utility>

namespace
{
using namespace IndoorGMLAdjacencyNative;
constexpr double EPSILON = 1.0e-9;
constexpr std::size_t MAX_CLUSTER_SIZE = 8;

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

bool meaningful_branch(std::size_t index,
                       const std::vector<std::vector<std::size_t>>& adj)
{
    const auto& connected=adj[index];
    if(connected.size()<=2) return false;
    std::vector<bool> reached(adj.size(),false);
    std::vector<std::size_t> queue{connected.front()};
    reached[connected.front()]=true;
    for(std::size_t head=0;head<queue.size();++head)
    {
        for(const std::size_t other:adj[queue[head]])
        {
            if(other==index || reached[other]) continue;
            reached[other]=true;
            queue.push_back(other);
        }
    }
    return std::any_of(connected.begin(),connected.end(),
        [&](std::size_t other){return !reached[other];});
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

bool contract_existing(ReferenceGraphStageSnapshot& graph,
                       const CellData& cell,
                       std::vector<std::size_t> members,
                       std::size_t representative,
                       double tolerance)
{
    std::sort(members.begin(),members.end());
    members.erase(std::unique(members.begin(),members.end()),members.end());
    if(members.size()<2 || !std::binary_search(members.begin(),members.end(),representative))
        return false;
    const auto adj=adjacency(graph);
    std::vector<bool> selected(graph.nodes.size(),false);
    for(const auto index:members)
    {
        if(index>=graph.nodes.size()) return false;
        selected[index]=true;
        if(index!=representative && graph.protected_nodes[index]) return false;
    }
    std::set<std::size_t> boundary;
    for(const auto index:members)
        for(const auto other:adj[index]) if(!selected[other]) boundary.insert(other);

    std::vector<std::pair<Vec3,Vec3>> checks;
    for(const auto index:members)
        if(index!=representative && !has_edge(adj,representative,index))
            checks.push_back({graph.nodes[representative].point,graph.nodes[index].point});
    for(const auto index:boundary)
        if(!has_edge(adj,representative,index))
            checks.push_back({graph.nodes[representative].point,graph.nodes[index].point});
    if(!clear_segments(cell,checks,tolerance)) return false;

    std::vector<bool> removed(graph.nodes.size(),false);
    for(const auto index:members) if(index!=representative) removed[index]=true;
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
    for(const auto& edge:graph.edges)
    {
        if(removed[edge.first] || removed[edge.second]) continue;
        result.edges.push_back({remap[edge.first],remap[edge.second]});
    }
    const std::size_t rep=remap[representative];
    for(const auto old:boundary) result.edges.push_back({rep,remap[old]});
    canonicalize_edges(result);
    graph=std::move(result);
    return true;
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

ReferenceGraphStageSnapshot build_after(const CellData& cell,
                                        const ReferenceGraphDebug& before,
                                        ReferenceGraphStageSnapshot graph,
                                        double tolerance)
{
    // Conservatively protect State and all certified-loop participants. The
    // reduction may retain more nodes than Ruby's old selector, never fewer
    // certified anchors.
    if(before.state_node_index && *before.state_node_index<graph.nodes.size())
        graph.protected_nodes[*before.state_node_index]=true;
    for(const auto& candidate:before.loop_candidates)
    {
        for(const auto index:candidate.vertices)
            if(index<graph.nodes.size()) graph.protected_nodes[index]=true;
        for(const auto index:candidate.visible_neighbors)
            if(index<graph.nodes.size()) graph.protected_nodes[index]=true;
    }

    std::vector<std::size_t> order(graph.nodes.size());
    for(std::size_t i=0;i<order.size();++i) order[i]=i;
    std::sort(order.begin(),order.end(),[&](std::size_t a,std::size_t b){
        const double ra=graph.nodes[a].radius,rb=graph.nodes[b].radius;
        if(ra!=rb) return ra>rb;
        return a<b;
    });
    for(const auto original_center:order)
    {
        auto center_it=std::find(graph.original_indices.begin(),graph.original_indices.end(),
                                 std::optional<std::size_t>(original_center));
        if(center_it==graph.original_indices.end()) continue;
        std::size_t center=static_cast<std::size_t>(center_it-graph.original_indices.begin());
        if(graph.protected_nodes[center]) continue;
        const auto adj=adjacency(graph);
        std::vector<std::size_t> candidates=adj[center];
        std::sort(candidates.begin(),candidates.end(),[&](std::size_t a,std::size_t b){
            if(graph.nodes[a].radius!=graph.nodes[b].radius)
                return graph.nodes[a].radius<graph.nodes[b].radius;
            return a<b;
        });
        std::vector<std::size_t> members{center};
        for(const auto index:candidates)
        {
            if(members.size()>=MAX_CLUSTER_SIZE) break;
            if(graph.protected_nodes[index] || adj[index].size()<2 || meaningful_branch(index,adj))
                continue;
            if(graph.nodes[index].radius>graph.nodes[center].radius+EPSILON) continue;
            if(distance(graph.nodes[center].point,graph.nodes[index].point)>=
               std::max(graph.nodes[center].radius,graph.nodes[index].radius)) continue;
            members.push_back(index);
        }
        while(members.size()>1)
        {
            if(contract_existing(graph,cell,members,center,tolerance)) break;
            members.pop_back();
        }
    }
    return graph;
}

ReferenceGraphStageSnapshot build_collapsed(const CellData& cell,
                                            const ReferenceGraphDebug& before,
                                            ReferenceGraphStageSnapshot graph,
                                            double tolerance)
{
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

ReferenceGraphStageSnapshot build_optimized(const CellData& cell,
                                            ReferenceGraphStageSnapshot graph,
                                            double tolerance)
{
    for(;;)
    {
        const auto adj=adjacency(graph);
        bool changed=false;
        for(std::size_t middle=0;middle<graph.nodes.size();++middle)
        {
            if(graph.protected_nodes[middle] || adj[middle].size()!=2) continue;
            const std::size_t representative=std::min(adj[middle][0],adj[middle][1]);
            const std::size_t other=std::max(adj[middle][0],adj[middle][1]);
            if(!projected_between(graph.nodes[representative].point,
                                  graph.nodes[middle].point,
                                  graph.nodes[other].point)) continue;
            if(contract_existing(graph,cell,{representative,middle},representative,tolerance))
            {
                changed=true;
                break;
            }
        }
        if(!changed) break;
    }
    return graph;
}

struct BridgeCandidate
{
    std::size_t first;
    std::size_t second;
    double squared_distance;
};

bool bridge_candidate_less(const BridgeCandidate& a,const BridgeCandidate& b)
{
    return std::tie(a.squared_distance,a.first,a.second)<
           std::tie(b.squared_distance,b.first,b.second);
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

std::size_t bridge_key(std::size_t first,std::size_t second,std::size_t count)
{
    if(second<first) std::swap(first,second);
    return first*count+second;
}

std::vector<BridgeCandidate> nearest_bridge_candidates(
    const ReferenceGraphStageSnapshot& graph,
    const std::vector<bool>& reached,
    const std::unordered_set<std::size_t>& rejected,
    std::size_t limit)
{
    const auto worse_first=[](const BridgeCandidate& a,const BridgeCandidate& b) {
        return bridge_candidate_less(a,b);
    };
    std::priority_queue<BridgeCandidate,std::vector<BridgeCandidate>,
                        decltype(worse_first)> nearest(worse_first);
    const std::size_t count=graph.nodes.size();
    for(std::size_t first=0;first<count;++first)
    {
        if(!reached[first]) continue;
        for(std::size_t second=0;second<count;++second)
        {
            if(reached[second]) continue;
            if(rejected.count(bridge_key(first,second,count))>0) continue;
            const Vec3& a=graph.nodes[first].point;
            const Vec3& b=graph.nodes[second].point;
            const double x=a.x-b.x,y=a.y-b.y,z=a.z-b.z;
            const double squared_distance=x*x+y*y+z*z;
            if(!std::isfinite(squared_distance) || squared_distance<=EPSILON*EPSILON)
                continue;
            const BridgeCandidate candidate{first,second,squared_distance};
            if(nearest.size()<limit)
                nearest.push(candidate);
            else if(bridge_candidate_less(candidate,nearest.top()))
            {
                nearest.pop();
                nearest.push(candidate);
            }
        }
    }
    std::vector<BridgeCandidate> result;
    result.reserve(nearest.size());
    while(!nearest.empty())
    {
        result.push_back(nearest.top());
        nearest.pop();
    }
    std::sort(result.begin(),result.end(),bridge_candidate_less);
    return result;
}

struct ConnectivityResult
{
    std::size_t added_edges=0;
    std::size_t unreachable_nodes=0;
};

ConnectivityResult connect_optimized_to_state(
    ReferenceGraphStageSnapshot& graph,const CellData& cell,
    std::size_t state_node_index,double tolerance)
{
    constexpr std::size_t INITIAL_CANDIDATE_BATCH=16;
    ConnectivityResult result;
    if(state_node_index>=graph.nodes.size())
    {
        result.unreachable_nodes=graph.nodes.size();
        return result;
    }

    for(;;)
    {
        const std::vector<bool> reached=reachable_nodes(graph,state_node_index);
        const std::size_t reached_count=static_cast<std::size_t>(
            std::count(reached.begin(),reached.end(),true));
        if(reached_count==graph.nodes.size()) break;

        std::unordered_set<std::size_t> rejected;
        std::size_t batch_size=INITIAL_CANDIDATE_BATCH;
        bool added=false;
        for(;;)
        {
            const auto candidates=nearest_bridge_candidates(
                graph,reached,rejected,batch_size);
            if(candidates.empty()) break;

            std::vector<std::pair<Vec3,Vec3>> segments;
            segments.reserve(candidates.size());
            for(const auto& candidate:candidates)
                segments.push_back({graph.nodes[candidate.first].point,
                                    graph.nodes[candidate.second].point});
            const auto visible=validate_room_reference_segments(
                cell,segments,tolerance);
            if(visible.size()!=candidates.size())
                throw std::runtime_error("Native Reference bridge LOS result size mismatch");
            for(std::size_t i=0;i<candidates.size();++i)
            {
                if(!visible[i]) continue;
                graph.edges.push_back({candidates[i].first,candidates[i].second});
                canonicalize_edges(graph);
                ++result.added_edges;
                added=true;
                break;
            }
            if(added) break;

            for(const auto& candidate:candidates)
                rejected.insert(bridge_key(
                    candidate.first,candidate.second,graph.nodes.size()));
            if(candidates.size()<batch_size) break;
            if(batch_size>std::numeric_limits<std::size_t>::max()/2) break;
            batch_size*=2;
        }
        if(!added)
        {
            result.unreachable_nodes=graph.nodes.size()-reached_count;
            break;
        }
    }
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
ReferenceGraphPipeline build_state_reference_graph_pipeline(
    const Vec3& state_point,const CellData& cell,double tolerance)
{
    ReferenceGraphPipeline result;
    result.before.nodes.push_back({state_point,0.0});
    result.before.original_indices.push_back(0);
    result.before.protected_nodes.push_back(true);
    result.after=result.before;
    result.collapsed=result.before;
    result.optimized=result.before;
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
    result.after=build_after(cell,before,result.before,tolerance);
    result.collapsed=build_collapsed(cell,before,result.after,tolerance);
    result.optimized=build_optimized(cell,result.collapsed,tolerance);

    const auto state_original=*before.state_node_index;
    const auto found=std::find(result.optimized.original_indices.begin(),
                               result.optimized.original_indices.end(),
                               std::optional<std::size_t>(state_original));
    if(found==result.optimized.original_indices.end())
        throw std::runtime_error("Reference State node did not survive Native reductions");
    result.state_node_index=static_cast<std::size_t>(found-result.optimized.original_indices.begin());
    const ConnectivityResult connectivity=connect_optimized_to_state(
        result.optimized,cell,result.state_node_index,tolerance);
    result.optimized_bridge_count=connectivity.added_edges;
    result.unreachable_node_count=connectivity.unreachable_nodes;
    result.shortest_path_tree=bake_tree(result.optimized,result.state_node_index);
    // clear_session() discards CellData, so retain a self-contained Face BVH
    // for LOS checks made after the final waypoint coordinates are known.
    result.waypoint_solid=std::make_shared<FaceSolid>(cell,tolerance);
    result.waypoint_tolerance=tolerance;
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
    for(auto* stage:{&pipeline.before,&pipeline.after,
                     &pipeline.collapsed,&pipeline.optimized})
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
    case ReferenceGraphStage::After:return pipeline.after;
    case ReferenceGraphStage::Collapsed:return pipeline.collapsed;
    case ReferenceGraphStage::Optimized:return pipeline.optimized;
    }
    return pipeline.optimized;
}

std::optional<Vec3> closest_reachable_reference_point(
    const ReferenceGraphPipeline& pipeline,const Vec3& waypoint)
{
    const auto& graph=pipeline.optimized;
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
    const auto& graph=pipeline.optimized;
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
