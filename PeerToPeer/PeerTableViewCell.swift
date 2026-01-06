//
//  PeerTableViewCell.swift
//  PlotterSwift
//
//  Created by Steve Wainwright on 05/05/2018.
//  Copyright © 2018 Whichtoolface.com. All rights reserved.
//

import UIKit

class DeviceTableViewCell: UITableViewCell {
    
    @IBOutlet weak var peerName: UILabel?
    @IBOutlet weak var peerIdentifierUIID: UILabel?
    
    override func awakeFromNib() {
        super.awakeFromNib()
        // Initialization code
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        // Configure the view for the selected state
    }

}
