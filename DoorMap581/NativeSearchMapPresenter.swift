import MapKit
import UIKit

/// Materialize screen groups, not one MapKit accessibility object for every
/// result across 3 km. The full pool stays in memory and in the paged list.
@MainActor final class NativeSearchMapPresenter {
    struct Stats {
        var poolCount=0, renderedAnnotations=0, renderedMembers=0, offscreen=0, unprojectable=0
        var renderCount=0, maximumMillis=0.0
    }
    private weak var map: MKMapView?
    private var pool: [DoorSearchCore.Result] = []
    private var annotations: [String: MKAnnotation] = [:]
    private var rendering=false
    private(set) var stats=Stats()
    init(map: MKMapView) { self.map=map }
    func setResults(_ results: [DoorSearchCore.Result]) { pool=results; refresh() }
    func clear() {
        if let map { map.removeAnnotations(Array(annotations.values)) }
        annotations.removeAll(); pool.removeAll(); stats=Stats()
    }
    func refresh() {
        guard let map, map.bounds.width > 0, map.bounds.height > 0, !rendering else { return }
        rendering=true; defer { rendering=false }
        let start=CFAbsoluteTimeGetCurrent()
        let byID=Dictionary(pool.map { ($0.id,$0) }, uniquingKeysWith: { first,_ in first })
        let projected=pool.map { result -> DoorSearchMapLayout.Point in
            let c=result.record.coordinate
            let p=map.convert(CLLocationCoordinate2D(latitude:c.lat,longitude:c.lng),toPointTo:map)
            return .init(id:result.id,x:Double(p.x),y:Double(p.y))
        }
        let plan=DoorSearchMapLayout.plan(projected,width:Double(map.bounds.width),height:Double(map.bounds.height))
        var next:[String:MKAnnotation]=[:], add:[MKAnnotation]=[]
        var visibleMembers=0, unprojectable=plan.unprojectableIDs.count
        for group in plan.groups {
            let members=group.memberIDs.compactMap { byID[$0] }
            guard !members.isEmpty else { continue }
            let key=group.key
            let annotation: MKAnnotation
            if members.count == 1, let first=members.first {
                // Singletons always use their original geographic anchor, never a grid centroid.
                if let prior=annotations[key] as? NativeSearchAnnotation, prior.result == first { annotation=prior }
                else { annotation=NativeSearchAnnotation(result:first); add.append(annotation) }
            } else {
                let c=map.convert(CGPoint(x:group.x,y:group.y),toCoordinateFrom:map)
                guard CLLocationCoordinate2DIsValid(c) else { unprojectable += members.count; continue }
                if let prior=annotations[key] as? NativeSearchGroupAnnotation, prior.members == members {
                    if prior.coordinate.latitude != c.latitude || prior.coordinate.longitude != c.longitude { prior.coordinate=c }
                    annotation=prior
                } else { annotation=NativeSearchGroupAnnotation(members:members,coordinate:c); add.append(annotation) }
            }
            next[key]=annotation; visibleMembers += members.count
        }
        let remove=annotations.compactMap { key,value -> MKAnnotation? in
            guard let retained=next[key], ObjectIdentifier(value) == ObjectIdentifier(retained) else { return value }
            return nil
        }
        annotations=next
        if !remove.isEmpty { map.removeAnnotations(remove) }
        if !add.isEmpty { map.addAnnotations(add) }
        stats.poolCount=byID.count; stats.renderedAnnotations=next.count
        stats.renderedMembers=visibleMembers; stats.offscreen=plan.offscreenIDs.count; stats.unprojectable=unprojectable
        stats.renderCount += 1; stats.maximumMillis=max(stats.maximumMillis,(CFAbsoluteTimeGetCurrent()-start)*1000)
    }
    func annotationView(for annotation: MKAnnotation) -> MKAnnotationView? {
        guard let map else { return nil }
        if let item=annotation as? NativeSearchAnnotation {
            let v=map.dequeueReusableAnnotationView(withIdentifier:"native-search-dot") as? NativeSearchDotView
                ?? NativeSearchDotView(annotation:item,reuseIdentifier:"native-search-dot")
            v.annotation=item; v.configure(item); v.clusteringIdentifier=nil
            return v
        }
        if let group=annotation as? NativeSearchGroupAnnotation {
            let v=map.dequeueReusableAnnotationView(withIdentifier:"native-screen-search-cluster") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation:group,reuseIdentifier:"native-screen-search-cluster")
            v.annotation=group; v.clusteringIdentifier=nil; v.canShowCallout=false
            v.markerTintColor=UIColor(red:0.66,green:0.22,blue:0.16,alpha:1)
            v.glyphText=String(group.members.count); v.displayPriority = .required
            v.accessibilityIdentifier="native-search-cluster"
            v.accessibilityLabel="\(group.members.count) 個地點，點按放大；重疊地點可逐一選取"
            v.accessibilityValue=String(group.members.count)
            return v
        }
        return nil
    }
}

final class NativeSearchGroupAnnotation: NSObject, MKAnnotation {
    let members: [DoorSearchCore.Result]
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { "\(members.count) 個地點" }
    init(members:[DoorSearchCore.Result],coordinate:CLLocationCoordinate2D) {
        self.members=members; self.coordinate=coordinate; super.init()
    }
}

/// Coincident/max-zoom clusters remain selectable without an infinite zoom loop.
/// UITableView virtualizes cells; it does not discard members beyond a page limit.
@MainActor final class NativeSearchMembersViewController: UITableViewController {
    private let members:[DoorSearchCore.Result]
    var onSelect: ((DoorSearchRecord)->Void)?
    init(members:[DoorSearchCore.Result]) { self.members=members; super.init(style:.plain) }
    @available(*,unavailable) required init?(coder:NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad(); title="\(members.count) 個重疊地點"
        tableView.accessibilityIdentifier="native-cluster-members"
        tableView.rowHeight=UITableView.automaticDimension; tableView.estimatedRowHeight=70
        navigationItem.rightBarButtonItem=UIBarButtonItem(title:"完成",style:.done,target:self,action:#selector(close))
    }
    override func tableView(_ tableView:UITableView,numberOfRowsInSection section:Int)->Int { members.count }
    override func tableView(_ tableView:UITableView,cellForRowAt indexPath:IndexPath)->UITableViewCell {
        let cell=tableView.dequeueReusableCell(withIdentifier:"cluster-member") ?? UITableViewCell(style:.subtitle,reuseIdentifier:"cluster-member")
        let value=members[indexPath.row]
        cell.textLabel?.text=value.record.displayName; cell.textLabel?.numberOfLines=0
        cell.detailTextLabel?.text=DoorSearchCore.locationText(value.record); cell.detailTextLabel?.numberOfLines=0
        cell.accessibilityIdentifier="native-cluster-member-\(indexPath.row)"; cell.accessibilityValue=value.id
        return cell
    }
    override func tableView(_ tableView:UITableView,didSelectRowAt indexPath:IndexPath) {
        let record=members[indexPath.row].record, callback=onSelect
        dismiss(animated:true) { callback?(record) }
    }
    @objc private func close() { dismiss(animated:true) }
}
