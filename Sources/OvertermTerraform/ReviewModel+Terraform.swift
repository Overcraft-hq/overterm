import Foundation

extension ReviewModel {
    /// The review's Terraform section: the roots it touches, their plans.
    package var terraform: TerraformReviewModel {
        if let model = terraformStorage as? TerraformReviewModel { return model }
        let model = TerraformReviewModel()
        terraformStorage = model
        return model
    }
}
