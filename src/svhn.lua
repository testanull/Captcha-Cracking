require 'nn'
require 'nngraph'
require 'optim'
require 'gnuplot'
require 'decoder'

cmd = torch.CmdLine()
cmd:text()
cmd:text("Options:")

-- global:
cmd:option('-gpuid', -1, 'id of gpu, negative values like -1 means using CPU')
-- cmd:option('-threads', 2, 'number of threads')
cmd:option('-model', '', 'using trained model')
cmd:option('-dropout', 0.5, 'prob of dropout for model')
cmd:option('-savename', 'model.t7', 'the name of model to save')
cmd:option('-dataname', 'fullset.dat', 'name of data set to load')

-- training
cmd:option('-learningRate', 1e-3,'learning rate at t = 0')
cmd:option('-learningRateDecay', 0,'learning rate decay')
cmd:option('-momentum', 0.9,'momentum (SGD only)')
cmd:option('-weightDecay', 1e-3,'weight Decay')
cmd:option('-alpha', 0.95, 'alpha for optim.rmsprop')
cmd:option('-max_epochs', 1000, 'maximum epchos')
cmd:option('-validfreq', 1, 'epochs to do the validation')
cmd:option('-savefreq', 100, 'epochs to save the model ')
cmd:text()

opt = cmd:parse(arg or {})

data_util = require 'svhn_data'
model_util = require 'svhn_model'

print("loading data...")
trainset, validset = data_util.getFullset(opt.dataname)
print("trainset.size = ", trainset.size)
print("validset.size = ", validset.size)

if opt.gpuid > 0 then
    require 'cutorch'
    require 'cunn'
    trainset.data = trainset.data:cuda()
    trainset.labels = trainset.labels:cuda()
    validset.data = validset.data:cuda()
    validset.labels = validset.labels:cuda()
    print(cutorch.getDeviceCount(), "GPU devices detected")
    cutorch.setDevice(opt.gpuid)
    print("running on GPU", opt.gpuid)
    local freeMem, totalMem = cutorch.getMemoryUsage(opt.gpuid)
    print(string.format("GPU %d has %dM memory left, with %dM totally",
        opt.gpuid, freeMem/1000000, totalMem/1000000))
end


model = nil
if opt.model == '' then
    print("building CNN model...")
    model = model_util.create(opt.dropout)
else
    print("loading CNN model...")
    model = torch.load(opt.model)
end

if opt.gpuid > 0 then
    model = model:cuda()
end

x, dl_dx = model:getParameters()
print(string.format("%d parameters", x:size()[1]))

sgd_params = {
    learningRate = opt.learningRate,
    learningRateDecay = opt.learningRateDecay,
    weightDecay = opt.weightDecay,
    momentum = opt.momentum,
}

-- step training
step = function(trainset)
    local avg_loss = 0
    local avg_accuracy = 0
    local shuffle = torch.randperm(trainset.size)
    for i = 1, trainset.size do
        local input = trainset.data[shuffle[i]]
        local label = trainset.labels[shuffle[i]]
        if opt.gpuid > 0 then
            input = input:cuda()
            label = label:cuda()
        end

        local feval = function()
            local output = model:forward(input)
            local pL = output[1]:storage() -- output of length L
            local pS = output[2]:storage() -- output of character S[1..L]

            -- 1. calc loss
            local loss = pL[label[1] + 1]
            for j = 2, label[1]+1 do
                local index = (j - 2) * 20 + label[j]
                loss = loss + pS[index]
            end

            -- 2. count correct labels
            prediction = output2label(output)
            if compareLabel(prediction, label) then
                avg_accuracy = avg_accuracy + 1
            end

            -- 3. calc outputGrad for pL and pS
            local l_grad = torch.Tensor(10):fill(0)
            local s_grad = torch.Tensor(160):fill(0)
            if opt.gpuid > 0 then
                l_grad = l_grad:cuda()
                s_grad = s_grad:cuda()
            end
            l_grad[label[1] + 1] = -1
            for j = 2, label[1]+1 do
                local index = (j - 2) * 20 + label[j]
                s_grad[index] = -1
            end

            -- 4. backward the outputGrad
            dl_dx:zero()
            local outputGrad = {l_grad, s_grad:reshape(8, 20)}
            model:backward(input, outputGrad)

            return -loss, dl_dx
        end

        local _, loss = optim.sgd(feval, x, sgd_params)
        avg_loss = avg_loss + loss[1]
    end
    avg_loss = avg_loss / trainset.size
    avg_accuracy = avg_accuracy / trainset.size
    return avg_loss, avg_accuracy
end


validate = function(validset)
    -- local demo_per_size = validset.size / 10
    local avg_loss = 0
    local avg_accuracy = 0
    local shuffle = torch.randperm(validset.size)
    for i = 1, validset.size do
        local input = validset.data[shuffle[i]]
        local label = validset.labels[shuffle[i]]
        if opt.gpuid > 0 then
            input = input:cuda()
            label = label:cuda()
        end

        local output = model:forward(input)
        prediction = output2label(output)
        if compareLabel(prediction, label) then
            avg_accuracy = avg_accuracy + 1
        end

        -- print several examples about prediction and label
        -- if i % demo_per_size == 0 then
            --print("prediction: ", label2str(prediction))
            -- print("label:\t", label2str(label))
            -- print("")
        -- end

        -- calc validation loss
        local pL = output[1]:storage() -- output of length L
        local pS = output[2]:storage() -- output of character S[1..L]
        local loss = pL[label[1] + 1]
        for j = 2, label[1]+1 do
            local index = (j - 2) * 20 + label[j]
            loss = loss + pS[index]
        end
        avg_loss = avg_loss + loss
    end
    avg_loss = - avg_loss / validset.size
    avg_accuracy = avg_accuracy / validset.size

    return avg_loss, avg_accuracy
end

train_loss_tensor = torch.Tensor(opt.max_epochs):fill(0)
valid_loss_tensor = torch.Tensor(opt.max_epochs / opt.validfreq):fill(0)
train_accuracy_tensor = torch.Tensor(opt.max_epochs):fill(0)
valid_accuracy_tensor = torch.Tensor(opt.max_epochs / opt.validfreq):fill(0)
--gnuplot.figure()
for i = 1, opt.max_epochs do
    local timer = torch.Timer()
    -- training
    model:training()
    local minLR = opt.learningRate * 0.001
    sgd_params.learningRate = opt.learningRate - i / opt.max_epochs * (opt.learningRate - minLR)
    local train_loss, train_accuracy = step(trainset)
    print(string.format("epochs = %d,\tloss = %.4f, accuracy = %.4f, costs %.2fs",
        i, train_loss, train_accuracy, timer:time().real))
    train_loss_tensor[i] = train_loss
    train_accuracy_tensor[i] = train_accuracy
    --gnuplot.plot(loss_tensor[{{1, i}}])

    -- validating
    if i % opt.validfreq == 0 then
        model:evaluate()
        local valid_loss, valid_accuracy = validate(validset)
        valid_loss_tensor[i / opt.validfreq] = valid_loss
        valid_accuracy_tensor[i / opt.validfreq] = valid_accuracy
        print(string.format("   validset:\tloss = %.4f, accuracy = %.4f",
            valid_loss, valid_accuracy))
    end

    -- saving model
    if i % opt.savefreq == 0 then
        print("==================================")
        print(string.format("\nsaving model as %s\n", opt.savename))
        print("==================================")
        torch.save(opt.savename, model)
        print("learningRate is:", sgd_params.learningRate)
    end
end

-- print all information during the training process
for i = 1, opt.max_epochs do
    print(string.format("i = %d,\ttrain_loss = %.4f, train_accuracy = %.4f",
        i, train_loss_tensor[i], train_accuracy_tensor[i]))

    if i % opt.validfreq == 0 then
        print(string.format('\tvalid_loss = %.4f, valid_accuracy = %.4f ',
            valid_loss_tensor[i / opt.validfreq],
            valid_accuracy_tensor[i / opt.validfreq]))
    end
end
